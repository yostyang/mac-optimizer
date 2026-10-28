// 充电控制：App 侧客户端（XPC）与界面卡片
import SwiftUI
import AppKit
import ServiceManagement

final class ChargeClient: ObservableObject {
    enum Phase: Equatable { case unsupported, notInstalled, needsApproval, starting, ready, failed(String) }
    static var shared = ChargeClient()
    @Published var phase: Phase = .notInstalled
    @Published var st = ChargeStatus()
    @Published var busy = false
    @Published var note = ""
    let localCaps: ChargeCaps
    var offline = false                 // 测试/截图：不连接助手、不注册
    private var conn: NSXPCConnection?
    init(caps: ChargeCaps? = nil) {
        localCaps = caps ?? ChargeCaps.detect(RealSMC())   // 普通用户可读，不需要权限
        st.caps = localCaps
        if !localCaps.any { phase = .unsupported }
    }
    var daemon: SMAppService { SMAppService.daemon(plistName: ChargeConst.plistName) }

    func refresh() {
        guard !offline, localCaps.any else { return }
        switch daemon.status {
        case .notRegistered, .notFound: phase = .notInstalled; drop()
        case .requiresApproval: phase = .needsApproval; drop()
        case .enabled:
            if phase != .ready { phase = .starting }
            proxy { p in p.status { d in
                let s = try? JSONDecoder().decode(ChargeStatus.self, from: d)
                DispatchQueue.main.async { if let s { self.st = s; self.phase = .ready } }
            } }
        @unknown default: phase = .notInstalled
        }
    }
    /// 由用户点击触发：注册守护进程，系统会要求在「登录项与扩展」里允许
    func install() {
        guard !offline else { return }
        do { try daemon.register(); note = "" } catch { note = "注册失败：\(error.localizedDescription)" }
        refresh()
        if phase == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    func uninstall() {
        guard !offline else { return }
        busy = true
        let finish = {
            DispatchQueue.main.async {
                do { try self.daemon.unregister() } catch { self.note = "卸载失败：\(error.localizedDescription)" }
                self.busy = false; self.drop(); self.st = ChargeStatus(); self.st.caps = self.localCaps; self.refresh()
            }
        }
        if phase == .ready { proxy(onError: finish) { $0.resetDefaults { _, _ in finish() } } } else { finish() }
    }
    /// 升级后：助手自己会在文件被替换后退出、由 launchd 拉起新版本。这里只确认能连上；
    /// 连不上时注销再注册（授权按助手 cdhash 记录，build.sh 保证助手不变时 cdhash 不变）。
    static let buildKey = "chargeHelperBuild"
    func repairAfterUpdate(completion: ((Bool) -> Void)? = nil) {
        guard !offline, localCaps.any else { completion?(false); return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let d = UserDefaults.standard
        guard daemon.status == .enabled, d.string(forKey: Self.buildKey) != build else {
            if daemon.status != .enabled { d.set(build, forKey: Self.buildKey) }
            completion?(true); return
        }
        DispatchQueue.global(qos: .utility).async {
            var ok = false
            for _ in 0..<5 where !ok { ok = ChargeClient.ping(); if !ok { Thread.sleep(forTimeInterval: 2) } }
            // 替换 App 包后 launchd 找不到包内相对路径（EX_CONFIG）：注销再注册一次即可恢复。
            // 助手 cdhash 不变时用户授权会保留（v1.5 实测）；助手代码变化时才需要重新允许。
            for _ in 0..<2 where !ok {
                try? self.daemon.unregister(); Thread.sleep(forTimeInterval: 3)
                do { try self.daemon.register() } catch { continue }
                for _ in 0..<6 where !ok { Thread.sleep(forTimeInterval: 2); ok = ChargeClient.ping() }
            }
            DispatchQueue.main.async {
                if ok { d.set(build, forKey: Self.buildKey) } else { self.note = "升级后充电助手没有启动，请在「登录项与扩展」里确认已允许" }
                self.drop(); self.refresh(); completion?(ok)
            }
        }
    }
    /// 独立连接探测助手是否在运行（同证书校验）
    static func ping() -> Bool {
        let c = NSXPCConnection(machServiceName: ChargeConst.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        if #available(macOS 13.0, *) { c.setCodeSigningRequirement("identifier \"\(ChargeConst.label)\" and certificate leaf = H\"\(ChargeConst.certLeaf)\"") }
        c.resume(); defer { c.invalidate() }
        let sem = DispatchSemaphore(value: 0); var ok = false
        let p = c.remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? ChargeHelperProtocol
        p?.status { d in ok = !d.isEmpty; sem.signal() }
        _ = sem.wait(timeout: .now() + 3); return ok
    }
    private func drop() { conn?.invalidate(); conn = nil }
    private func proxy(onError: (() -> Void)? = nil, _ f: (ChargeHelperProtocol) -> Void) {
        if conn == nil {
            let c = NSXPCConnection(machServiceName: ChargeConst.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
            // 反向校验：只和同一证书签名的助手通信
            if #available(macOS 13.0, *) { c.setCodeSigningRequirement("identifier \"\(ChargeConst.label)\" and certificate leaf = H\"\(ChargeConst.certLeaf)\"") }
            c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.conn = nil } }
            c.resume(); conn = c
        }
        let p = conn?.remoteObjectProxyWithErrorHandler { [weak self] e in
            DispatchQueue.main.async { self?.note = "无法连接充电助手：\(e.localizedDescription)"; onError?() }
        } as? ChargeHelperProtocol
        if let p { f(p) }
    }
    private func done(_ ok: Bool, _ msg: String) { DispatchQueue.main.async { if !ok { self.note = msg }; self.refresh() } }
    func setLimit(_ v: Int, enabled: Bool) { st.settings.limit = v; st.settings.enabled = enabled; guard !offline else { return }; proxy { $0.setLimit(v, enabled: enabled, reply: done) } }
    func setSail(_ v: Int) { st.settings.sail = v; guard !offline else { return }; proxy { $0.setSailing(v, reply: done) } }
    func setDischarge(_ on: Bool) { st.settings.autoDischarge = on; guard !offline else { return }; proxy { $0.setAutoDischarge(on, reply: done) } }
    func setLED(_ on: Bool) { st.settings.led = on; guard !offline else { return }; proxy { $0.setLED(on, reply: done) } }
    func topUp(_ on: Bool) { st.topUp = on; guard !offline else { return }; proxy { $0.setTopUp(on, reply: done) } }
}

struct ChargeCard: View {
    @ObservedObject var c: ChargeClient
    var body: some View {
        Card(title: "充电控制", icon: "bolt.batteryblock") {
            switch c.phase {
            case .unsupported:
                small("这台 Mac 的固件没有可用的充电控制键，无法限制充电。可以使用 macOS 自带的「充电上限」（80–100%）：")
                Button { SystemPanes.battery() } label: { Label("打开系统设置 › 电池", systemImage: "gear") }.buttonStyle(PillButton(filled: false))
            case .notInstalled, .needsApproval, .starting, .failed:
                small("充电上限等需要后台助手（系统设置里允许一次）。默认不装。本机用断开电源实现上限，接外接显示器时会自动暂停。")
                small("本机支持：" + capsText(c.localCaps)).accessibilityIdentifier("charge.caps")
                if c.phase == .needsApproval {
                    small("等待授权：在「系统设置 › 通用 › 登录项与扩展」里打开「Mac一键优化」的后台项目开关，并输入管理员密码。").foregroundColor(.orange)
                    HStack {
                        Button { SMAppService.openSystemSettingsLoginItems() } label: { Label("打开登录项设置", systemImage: "gear") }.buttonStyle(PillButton())
                        Button("取消安装") { c.uninstall() }.buttonStyle(PillButton(filled: false))
                    }
                } else if c.phase == .starting {
                    small("助手已允许，正在连接…")
                } else {
                    Button { c.install() } label: { Label("安装充电助手", systemImage: "lock.shield") }.buttonStyle(PillButton()).accessibilityIdentifier("charge.install")
                }
            case .ready:
                controls
            }
            if !c.note.isEmpty { small(c.note).foregroundColor(.orange) }
        }
    }
    func small(_ s: String) -> some View { Text(s).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
    func capsText(_ k: ChargeCaps) -> String {
        var a: [String] = []
        a.append(k.inhibit != .none ? "暂停充电" : (k.adapter ? "断开电源实现上限" : "无"))
        if k.adapter && k.inhibit != .none { a.append("自动放电") }
        if k.led { a.append("MagSafe 灯") }
        return a.joined(separator: " · ")
    }
    var stateText: String {
        let s = c.st
        if !s.settings.enabled { return "未启用：按系统默认充电" }
        if s.displayPaused == true && s.caps.adapterMode { return s.externalDisplay == true ? "已暂停：接了外接显示器" : "外接显示器已拔掉，稍后恢复上限" }
        if s.topUp { return "临时充到 100%（拔掉电源或充满后恢复上限）" }
        if s.adapterCut { return "已到上限，正在用电池供电（降到 \(s.settings.limit - max(s.settings.sail, 1))% 再接通电源）" }
        if s.inhibited { return "已保持在上限，暂停充电" }
        return s.plugged ? "充电中，到 \(s.settings.limit)% 停止" : "电池供电"
    }
    @ViewBuilder var controls: some View {
        let s = c.st
        HStack {
            Toggle("启用充电上限", isOn: Binding(get: { s.settings.enabled }, set: { c.setLimit(s.settings.limit, enabled: $0) })).toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("charge.enabled")
            Spacer()
            Text(stateText).font(.system(size: 10)).foregroundColor(s.adapterCut || s.inhibited ? good : .secondary).lineLimit(2).multilineTextAlignment(.trailing)
        }.font(.system(size: 12))
        Group {
            HStack(spacing: 6) {
                Text("上限")
                Slider(value: Binding(get: { Double(s.settings.limit) }, set: { c.setLimit(Int($0), enabled: s.settings.enabled) }), in: 50...100, step: 5).accessibilityIdentifier("charge.limit")
                Text("\(s.settings.limit)%").monospacedDigit().frame(width: 34, alignment: .trailing)
                Text("航行").padding(.leading, 6)
                Slider(value: Binding(get: { Double(s.settings.sail) }, set: { c.setSail(Int($0)) }), in: 0...10, step: 1).frame(maxWidth: 90).accessibilityIdentifier("charge.sail")
                Text("\(s.settings.sail)%").monospacedDigit().frame(width: 26, alignment: .trailing)
            }
            if s.displayPaused == true && s.caps.adapterMode {
                Label("接着外接显示器时不断开电源（否则显示器会掉线），先正常充电；拔掉显示器约 10 秒后自动恢复上限。", systemImage: "display")
                    .font(.system(size: 11)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("charge.paused")
            } else if s.caps.adapterMode {
                small("本机无停充键：到上限断开电源用电池，降到下沿再接通。")
            } else if s.caps.adapter {
                Toggle("高于上限时自动放电（插着电源也用电池）", isOn: Binding(get: { s.settings.autoDischarge }, set: { c.setDischarge($0) })).toggleStyle(.switch).controlSize(.small)
            }
        }.font(.system(size: 12)).disabled(!s.settings.enabled).opacity(s.settings.enabled ? 1 : 0.5)
        HStack(spacing: 8) {
            Button { c.topUp(!s.topUp) } label: { Label(s.topUp ? "取消充满" : "充到 100%", systemImage: "bolt.fill").lineLimit(1).fixedSize() }.buttonStyle(PillButton(filled: false)).disabled(!s.settings.enabled).accessibilityIdentifier("charge.topup")
            if s.caps.led {
                Toggle(isOn: Binding(get: { s.settings.led }, set: { c.setLED($0) })) { Text("MagSafe 灯").lineLimit(1).fixedSize() }.toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    .help("保持在上限时绿灯，充电时橙灯").disabled(!s.settings.enabled)
            }
            Spacer()
            Button { c.uninstall() } label: { Text("卸载充电助手").lineLimit(1).fixedSize() }.buttonStyle(PillButton(filled: false)).disabled(c.busy).accessibilityIdentifier("charge.uninstall")
        }
        small("与系统充电上限同开时取较低者。接外接屏时自动暂停。关/卸载即恢复默认。")
    }
}

/// 诊断命令行：--charge status | limit <n> <on|off> | sail <n> | topup <on|off> | led <on|off>（经同一 XPC 白名单）
enum ChargeCLI {
    static func run(_ a: [String]) -> Int32 {
        let c = NSXPCConnection(machServiceName: ChargeConst.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        if #available(macOS 13.0, *) { c.setCodeSigningRequirement("identifier \"\(ChargeConst.label)\" and certificate leaf = H\"\(ChargeConst.certLeaf)\"") }
        c.resume()
        let sem = DispatchSemaphore(value: 0); var rc: Int32 = 0
        let p = c.remoteObjectProxyWithErrorHandler { e in print("XPC 错误：\(e)"); rc = 2; sem.signal() } as! ChargeHelperProtocol
        let r: (Bool, String) -> Void = { ok, m in print(ok ? "ok" : "拒绝：\(m)"); if !ok { rc = 1 }; sem.signal() }
        let cmd = a.first ?? "status", v = a.count > 1 ? a[1] : "", on = (a.last == "on")
        switch cmd {
        case "limit": p.setLimit(Int(v) ?? 0, enabled: on, reply: r)
        case "sail": p.setSailing(Int(v) ?? -1, reply: r)
        case "topup": p.setTopUp(on, reply: r)
        case "led": p.setLED(on, reply: r)
        case "uninstall":
            // 先尽量复位，再注销（XPC 失败也继续注销）
            p.resetDefaults { _, _ in }; _ = sem.wait(timeout: .now() + 2)
            c.invalidate()
            do { try ChargeClient.shared.daemon.unregister(); print("ok unregistered") } catch { print("注销：\(error)"); rc = 1 }
            return rc
        case "install":
            c.invalidate()
            do { try ChargeClient.shared.daemon.register(); print("ok registered \(ChargeClient.shared.daemon.status.rawValue)") } catch { print("注册：\(error)"); rc = 1 }
            return rc
        default: p.status { d in print(String(data: d, encoding: .utf8) ?? ""); sem.signal() }
        }
        if sem.wait(timeout: .now() + 5) == .timedOut { print("超时"); rc = 3 }
        c.invalidate(); return rc
    }
}
