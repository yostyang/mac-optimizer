// 充电控制：App 侧客户端（XPC）与界面卡片
import SwiftUI
import AppKit
import ServiceManagement

final class ChargeClient: ObservableObject {
    enum Phase: Equatable { case unsupported, notInstalled, needsApproval, starting, ready, failed(String) }
    enum RetrySetting { case limit(Int, Bool), sail(Int), discharge(Bool), led(Bool), topUp(Bool) }
    static var shared = ChargeClient()
    @Published var phase: Phase = .notInstalled
    @Published var st = ChargeStatus()
    @Published var busy = false
    @Published var note = ""
    @Published var retrySetting: RetrySetting?
    @Published var upgrade: HelperUpgradeState = .none   // 2.9.2 升级后助手版本核对
    var helperProbe: HelperProbe = SystemHelperProbe()
    var helperControl: HelperControl = SystemHelperControl()
    var backupDefaults: UserDefaults = .standard
    private var requestID = 0
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
                DispatchQueue.main.async { if let s { self.st = s; self.phase = .ready; self.keepSettings(s.settings) } }
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
        requestID += 1
        retrySetting = nil
        busy = true
        ChargeSettingsBackup.clear(defaults: backupDefaults)   // 主动卸载 = 恢复默认，不再按备份补写
        let finish = {
            DispatchQueue.main.async {
                do { try self.daemon.unregister() } catch { self.note = "卸载失败：\(error.localizedDescription)" }
                self.busy = false; self.drop(); self.st = ChargeStatus(); self.st.caps = self.localCaps; self.refresh()
            }
        }
        if phase == .ready {
            proxy(onError: { self.busy = false }) { $0.resetDefaults { ok, msg in
                if ok { finish() }
                else { DispatchQueue.main.async { self.note = msg; self.busy = false; self.refresh() } }
            } }
        } else { finish() }
    }
    /// 每次启动核对充电助手：本次安装之前就在运行的旧助手（例如旧 App 被拖进废纸篓后仍在运行）会被切换到新版。
    /// 助手代码没变时授权保留；变了则明确提示去「登录项与扩展」再允许一次。原设置存在系统目录，不会丢。
    static let buildKey = "chargeHelperBuild"
    func repairAfterUpdate(completion: ((Bool) -> Void)? = nil) {
        guard !offline, localCaps.any else { completion?(false); return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let probe = helperProbe, control = helperControl
        guard control.status != .notRegistered, control.status != .notFound else {
            UserDefaults.standard.set(build, forKey: Self.buildKey); completion?(true); return
        }
        upgrade = .checking
        DispatchQueue.global(qos: .utility).async {
            let outcome = HelperCheck.run(probe: probe, control: control)
            DispatchQueue.main.async {
                switch outcome {
                case .ok, .skipped: self.upgrade = .none
                case .repaired: self.upgrade = .repaired; self.note = ""
                case .needsApproval: self.upgrade = .needsApproval
                case .failed(let m): self.upgrade = .failed(m)
                }
                let ok = outcome == .ok || outcome == .repaired
                if ok { UserDefaults.standard.set(build, forKey: Self.buildKey) }
                self.drop(); self.refresh(); completion?(ok)
            }
        }
    }
    /// 记住最近一次确认过的设置；新助手若意外读到默认设置，按备份补写一次
    private var restoredOnce = false
    func keepSettings(_ s: ChargeSettings) {
        if !restoredOnce, let restore = ChargeSettingsBackup.restoreNeeded(current: s, backup: ChargeSettingsBackup.load(defaults: backupDefaults)) {
            restoredOnce = true   // 每次启动最多补写一次，写不进去时不反复重试
            setLimit(restore.limit, enabled: restore.enabled)
            if restore.sail != s.sail { setSail(restore.sail) }
            if restore.autoDischarge != s.autoDischarge { setDischarge(restore.autoDischarge) }
            if restore.led != s.led, st.caps.led { setLED(restore.led) }
            note = ""
        } else if ChargeSettingsBackup.restoreNeeded(current: s, backup: ChargeSettingsBackup.load(defaults: backupDefaults)) == nil {
            ChargeSettingsBackup.save(s, defaults: backupDefaults)
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
    private func begin(_ action: RetrySetting) -> Int { requestID += 1; retrySetting = action; return requestID }
    private func done(_ ok: Bool, _ msg: String, id: Int) {
        DispatchQueue.main.async {
            guard id == self.requestID else { return }
            self.note = ok ? "" : msg
            if ok { self.retrySetting = nil }
            self.refresh()
        }
    }
    func retrySave() {
        guard let action = retrySetting else { return }
        switch action {
        case let .limit(v, enabled): setLimit(v, enabled: enabled)
        case let .sail(v): setSail(v)
        case let .discharge(on): setDischarge(on)
        case let .led(on): setLED(on)
        case let .topUp(on): topUp(on)
        }
    }
    func setLimit(_ v: Int, enabled: Bool) {
        let id = begin(.limit(v, enabled)); st.settings.limit = v; st.settings.enabled = enabled
        guard !offline else { return }
        proxy { $0.setLimit(v, enabled: enabled) { [weak self] ok, msg in self?.done(ok, msg, id: id) } }
    }
    func setSail(_ v: Int) {
        let id = begin(.sail(v)); st.settings.sail = v
        guard !offline else { return }
        proxy { $0.setSailing(v) { [weak self] ok, msg in self?.done(ok, msg, id: id) } }
    }
    func setDischarge(_ on: Bool) {
        let id = begin(.discharge(on)); st.settings.autoDischarge = on
        guard !offline else { return }
        proxy { $0.setAutoDischarge(on) { [weak self] ok, msg in self?.done(ok, msg, id: id) } }
    }
    func setLED(_ on: Bool) {
        let id = begin(.led(on)); st.settings.led = on
        guard !offline else { return }
        proxy { $0.setLED(on) { [weak self] ok, msg in self?.done(ok, msg, id: id) } }
    }
    func topUp(_ on: Bool) {
        let id = begin(.topUp(on)); st.topUp = on
        guard !offline else { return }
        proxy { $0.setTopUp(on) { [weak self] ok, msg in self?.done(ok, msg, id: id) } }
    }
}

struct ChargeCard: View {
    @ObservedObject var c: ChargeClient
    var body: some View {
        Card(title: "充电控制", icon: "bolt.batteryblock") {
            upgradeLine
            switch c.phase {
            case .unsupported:
                small("这台 Mac 的固件没有可用的充电控制键，无法限制充电。可以使用 macOS 自带的「充电上限」（80–100%）：")
                Button { SystemPanes.battery() } label: { Label("打开系统设置 › 电池", systemImage: "gear") }.buttonStyle(PillButton(filled: false))
            case .notInstalled, .needsApproval, .starting, .failed:
                small("充电上限等需要后台助手（系统设置里允许一次）。默认不装。本机用断开电源实现上限，接外接显示器时会自动暂停。")
                small("本机支持：" + capsText(c.localCaps)).accessibilityIdentifier("charge.caps")
                if c.phase == .needsApproval {
                    small("等待授权：在「系统设置 › 通用 › 登录项与扩展」里打开「Mac一键优化」的后台项目开关，并输入管理员密码。").foregroundColor(DS.text.warn)
                    if c.upgrade == .needsApproval { small("这是升级后的新版助手，需要再允许一次；原来的充电设置会保留，允许之前不会限制充电。").accessibilityIdentifier("charge.upgrade.approval") }
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
            if c.note.isEmpty && !c.st.lastError.isEmpty { StateLine(kind: .failed, text: c.st.lastError, id: "charge.error") }
            if !c.note.isEmpty {
                StateLine(kind: .failed, text: c.note, actions: c.retrySetting == nil ? [] : [.retry { c.retrySave() }], id: "charge.save.error")
            }
        }
    }
    @ViewBuilder var upgradeLine: some View {
        switch c.upgrade {
        case .checking: StateLine(kind: .loading, text: "正在核对充电助手版本", id: "charge.upgrade")
        case .repaired: StateLine(kind: .done, text: "已切换到新版充电助手", detail: "原来的充电设置已保留。", id: "charge.upgrade")
        case .failed(let m):
            StateLine(kind: .failed, text: m, detail: "旧助手仍按旧版逻辑工作。可以重试；仍不行时到「登录项与扩展」关闭再打开 Mac一键优化 的后台项目。",
                      actions: [.retry { c.repairAfterUpdate() }, StateAction(title: "登录项设置", symbol: "gear") { SMAppService.openSystemSettingsLoginItems() }],
                      id: "charge.upgrade")
        case .none, .needsApproval: EmptyView()
        }
    }
    func small(_ s: String) -> some View { Text(s).font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true) }
    func capsText(_ k: ChargeCaps) -> String {
        var a: [String] = []
        a.append(k.inhibit != .none ? "暂停充电" : (k.adapter ? "断开电源实现上限" : "无"))
        if k.adapter && k.inhibit != .none { a.append("自动放电") }
        if k.led { a.append("MagSafe 灯") }
        return a.joined(separator: " · ")
    }
    /// 与电池页顶部共用 ChargeSummary 的判断（2.14）
    var summary: ChargeSummary { ChargeSummary.make(phase: c.phase, st: c.st, reading: ChargeSummary.reading(Monitor.shared.s)) }
    @ViewBuilder var controls: some View {
        let s = c.st, sum = summary
        HStack {
            Toggle("启用充电上限", isOn: Binding(get: { s.settings.enabled }, set: { c.setLimit(s.settings.limit, enabled: $0) })).toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("charge.enabled")
            Spacer()
            Text(sum.cardLine(enabled: s.settings.enabled)).font(DS.sub()).foregroundColor(sum.holding ? DS.text.good : (sum.pause != nil ? DS.text.warn : DS.text.secondary)).lineLimit(2).multilineTextAlignment(.trailing)
        }.font(DS.sub())
        Group {
            HStack(spacing: 6) {
                Text("上限")
                Slider(value: Binding(get: { Double(s.settings.limit) }, set: { c.setLimit(Int($0), enabled: s.settings.enabled) }), in: 50...100, step: 5).accessibilityIdentifier("charge.limit")
                Text("\(s.settings.limit)%").monospacedDigit().frame(width: 34, alignment: .trailing)
                Text("航行").padding(.leading, 6)
                Slider(value: Binding(get: { Double(s.settings.sail) }, set: { c.setSail(Int($0)) }), in: 0...10, step: 1).frame(maxWidth: 90).accessibilityIdentifier("charge.sail")
                Text("\(s.settings.sail)%").monospacedDigit().frame(width: 26, alignment: .trailing)
            }
            if s.dockProtected == true && s.caps.adapterMode {
                Label("已识别 Plugable TBT4-UD5，保持扩展坞供电。断开扩展坞后，先关闭再开启上限以重新检测连接状态。", systemImage: "display")
                    .font(DS.sub()).foregroundColor(DS.text.warn).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("charge.paused")
            } else if s.displayPaused == true && s.caps.adapterMode {
                Label("接着外接显示器时不断开电源（否则显示器会掉线），先正常充电；拔掉显示器约 10 秒后自动恢复上限。", systemImage: "display")
                    .font(DS.sub()).foregroundColor(DS.text.warn).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("charge.paused")
            } else if s.caps.adapterMode {
                small("本机无停充键：到上限断开电源用电池，降到下沿再接通。")
            } else if s.caps.adapter {
                Toggle("高于上限时自动放电（插着电源也用电池）", isOn: Binding(get: { s.settings.autoDischarge }, set: { c.setDischarge($0) })).toggleStyle(.switch).controlSize(.small)
            }
        }.font(DS.sub()).disabled(!s.settings.enabled).opacity(s.settings.enabled ? 1 : 0.5)
        HStack(spacing: 8) {
            Button { c.topUp(!s.topUp) } label: { Label(s.topUp ? "取消充满" : "充到 100%", systemImage: "bolt.fill").lineLimit(1).fixedSize() }.buttonStyle(PillButton(filled: false)).disabled(!s.settings.enabled).accessibilityIdentifier("charge.topup")
            if s.caps.led {
                Toggle(isOn: Binding(get: { s.settings.led }, set: { c.setLED($0) })) { Text("MagSafe 灯").lineLimit(1).fixedSize() }.toggleStyle(.switch).controlSize(.small).font(DS.sub())
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
