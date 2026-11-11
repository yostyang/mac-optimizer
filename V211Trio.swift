// 2.11：菜单栏「合并状态」图标（Wi-Fi、音量、电池合成一个图标）+ 面板里的音量与 Wi-Fi 控制
// 设计参考开源项目 status-trio 的思路，代码为独立实现。只用公开框架：CoreWLAN 读信号、CoreAudio 读写音量。
// 不需要新权限；只有「显示 Wi-Fi 名称」需要定位权限，默认关闭，用户打开时才申请。
import SwiftUI
import AppKit
import Combine
import CoreWLAN
import CoreAudio
import AudioToolbox
import CoreLocation

// MARK: - 配置（用户可调）
enum TrioItem: String, Codable, CaseIterable {
    case wifi, volume, battery
    var title: String { switch self { case .wifi: return "Wi-Fi"; case .volume: return "音量"; case .battery: return "电池" } }
}

struct TrioConfig: Codable, Equatable {
    var items: [TrioItem] = TrioItem.allCases   // 显示哪几项（顺序固定：Wi-Fi、音量、电池）
    var compact = false                         // 紧凑：Wi-Fi 与音量上下叠放；默认并排
    var percent = true                          // 电池里显示百分比数字
    var color = true                            // 电池按电量着色（默认）；关闭后整体单色、跟随菜单栏
    var size = 1                                // 0 小 / 1 中 / 2 大
    var panel = true                            // 面板里显示音量和 Wi-Fi 控制
    var wifiName = false                        // 面板里显示 Wi-Fi 名称（需要定位权限）

    static let key = "menubar.trio"
    /// 保证至少显示一项、顺序固定、大小在范围内
    func sanitized() -> TrioConfig {
        var c = self
        c.items = TrioItem.allCases.filter { items.contains($0) }
        if c.items.isEmpty { c.items = [.battery] }
        c.size = min(max(size, 0), 2)
        return c
    }
    func toggled(_ i: TrioItem) -> TrioConfig {
        var c = self
        if c.items.contains(i) { if c.items.count > 1 { c.items.removeAll { $0 == i } } } else { c.items.append(i) }
        return c.sanitized()
    }
    static func load(_ d: UserDefaults = .standard) -> TrioConfig {
        (d.data(forKey: key).flatMap { try? JSONDecoder().decode(TrioConfig.self, from: $0) } ?? TrioConfig()).sanitized()
    }
    func save(_ d: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(sanitized()) { d.set(data, forKey: Self.key) } }
}

// MARK: - 状态
struct WifiState: Equatable {
    enum Link: Equatable { case off, disconnected, connected, unavailable }
    var link: Link = .unavailable
    var rssi = 0
    var name: String? = nil
    /// 信号格数 0–3
    static func bars(rssi: Int) -> Int { rssi >= -60 ? 3 : (rssi >= -70 ? 2 : (rssi >= -85 ? 1 : 0)) }
    var bars: Int { link == .connected ? Self.bars(rssi: rssi) : 0 }
    var strength: String { ["很弱", "弱", "中", "强"][bars] }
    var summary: String {
        switch link {
        case .unavailable: return "这台 Mac 没有 Wi-Fi"
        case .off: return "Wi-Fi 已关闭"
        case .disconnected: return "未连接 Wi-Fi"
        case .connected: return (name.map { $0 + " · " } ?? "已连接 · ") + "信号\(strength)（\(rssi) dBm）"
        }
    }
}

struct VolumeState: Equatable {
    var level: Double? = nil      // 0–1；nil = 当前输出设备不能读音量（如部分显示器、HDMI）
    var muted = false
    var settable = false
    /// 图标用的音量档 0–3（静音或 0 为 0）
    var waves: Int { guard let l = level, !muted, l > 0.001 else { return 0 }; return l < 0.34 ? 1 : (l < 0.67 ? 2 : 3) }
    var text: String { level.map { muted ? "已静音" : "\(Int(($0 * 100).rounded()))%" } ?? "此输出设备不支持调节" }
}

/// 系统读数，抽成协议便于测试
protocol TrioSource {
    func wifi(withName: Bool) -> WifiState
    func volume() -> VolumeState
    func setVolume(_ v: Double)
    func setMuted(_ m: Bool)
}

struct SystemTrioSource: TrioSource {
    func wifi(withName: Bool) -> WifiState {
        guard let i = CWWiFiClient.shared().interface() else { return WifiState(link: .unavailable) }
        guard i.powerOn() else { return WifiState(link: .off) }
        let rssi = i.rssiValue()
        guard rssi != 0, i.wlanChannel() != nil else { return WifiState(link: .disconnected) }
        return WifiState(link: .connected, rssi: rssi, name: withName ? i.ssid() : nil)
    }
    static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }
    static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    static let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    func volume() -> VolumeState {
        guard let d = Self.device() else { return VolumeState() }
        var out = VolumeState()
        var a = Self.address(Self.volumeSelector)
        if AudioObjectHasProperty(d, &a) {
            var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr { out.level = Double(min(max(v, 0), 1)) }
            var can = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(d, &a, &can) == noErr { out.settable = can.boolValue }
        }
        var m = Self.address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(d, &m) {
            var v = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d, &m, 0, nil, &size, &v) == noErr { out.muted = v != 0 }
        }
        return out
    }
    func setVolume(_ v: Double) {
        guard let d = Self.device() else { return }
        var a = Self.address(Self.volumeSelector); var x = Float32(min(max(v, 0), 1))
        AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
    }
    func setMuted(_ m: Bool) {
        guard let d = Self.device() else { return }
        var a = Self.address(kAudioDevicePropertyMute); var x: UInt32 = m ? 1 : 0
        guard AudioObjectHasProperty(d, &a) else { return }
        AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &x)
    }
}

final class TrioModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TrioModel()
    @Published var config = TrioConfig.load() { didSet { if persist { config.save() }; refresh() } }
    @Published private(set) var wifi = WifiState()
    @Published private(set) var volume = VolumeState()
    var source: TrioSource = SystemTrioSource()
    var persist = true
    private var listening: Set<AudioDeviceID> = []
    private var systemListener = false
    private var location: CLLocationManager?

    func refresh() {
        let w = source.wifi(withName: config.wifiName), v = source.volume()
        if w != wifi { wifi = w }
        if v != volume { volume = v }
    }
    func setVolume(_ v: Double) { source.setVolume(v); if v > 0.001, volume.muted { source.setMuted(false) }; refresh() }
    func toggleMute() { source.setMuted(!volume.muted); refresh() }

    /// 音量和输出设备变化由系统事件通知，不用轮询；Wi-Fi 跟随现有的低频采样刷新
    func startListening() {
        if !systemListener {
            systemListener = true
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in self?.startListening(); self?.refresh() }
        }
        guard let d = SystemTrioSource.device(), !listening.contains(d) else { return }
        listening.insert(d)
        for sel in [SystemTrioSource.volumeSelector, kAudioDevicePropertyMute] {
            var a = SystemTrioSource.address(sel)
            guard AudioObjectHasProperty(d, &a) else { continue }
            AudioObjectAddPropertyListenerBlock(d, &a, .main) { [weak self] _, _ in self?.refresh() }
        }
    }

    // Wi-Fi 名称：系统要求定位权限
    var locationAllowed: Bool {
        let s = CLLocationManager().authorizationStatus
        return s == .authorizedAlways || s.rawValue == 4   // 4 = 使用期间允许
    }
    func requestWifiName() {
        let m = location ?? CLLocationManager(); location = m; m.delegate = self
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
        else if !locationAllowed, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(u) }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }
}

// MARK: - 图标布局（纯计算）与绘制
struct TrioLayout: Equatable {
    var size: CGSize
    var frames: [TrioItem: CGRect]
    static let heights: [CGFloat] = [14, 16, 18]
    static let spacing: CGFloat = 3

    static func make(_ config: TrioConfig, hasBattery: Bool) -> TrioLayout {
        let c = config.sanitized()
        var items = c.items.filter { $0 != .battery || hasBattery }
        if items.isEmpty { items = c.items.contains(.wifi) ? [.wifi] : [.volume] }
        let h = heights[c.size]
        var frames: [TrioItem: CGRect] = [:]
        var x: CGFloat = 0
        let stacked = c.compact && items.contains(.wifi) && items.contains(.volume)
        if stacked {
            // 叠放时两个符号都很小，用专门画的简化图形：上面是 Wi-Fi 扇形（占大半），下面是一条音量刻度
            let top = (h * 0.56).rounded(), w = (h * 1.05).rounded()
            frames[.wifi] = CGRect(x: 0, y: h - top, width: w, height: top)         // y 向上：Wi-Fi 在上
            frames[.volume] = CGRect(x: 0, y: 0, width: w, height: h - top - 1.5)
            x = w + spacing
        } else {
            for i in items where i != .battery {
                let w = (h * (i == .wifi ? 1.2 : 1.25)).rounded()
                frames[i] = CGRect(x: x, y: 0, width: w, height: h); x += w + spacing
            }
        }
        if items.contains(.battery) {
            let w = (h * 1.95).rounded()
            frames[.battery] = CGRect(x: x, y: 0, width: w, height: h); x += w + spacing
        }
        return TrioLayout(size: CGSize(width: max(1, x - spacing), height: h), frames: frames)
    }
}

enum TrioIcon {
    static func wifiSymbol(_ w: WifiState) -> (name: String, value: Double?) {
        switch w.link {
        case .off, .unavailable: return ("wifi.slash", nil)
        case .disconnected: return ("wifi", 0)
        case .connected: return ("wifi", [0.1, 0.34, 0.67, 1][w.bars])
        }
    }
    static func volumeSymbol(_ v: VolumeState) -> (name: String, value: Double?) {
        if v.level == nil { return ("speaker.fill", nil) }
        if v.muted || v.waves == 0 { return ("speaker.slash.fill", nil) }
        return ("speaker.wave.3.fill", [0, 0.34, 0.67, 1][v.waves])
    }
    static func symbol(_ s: (name: String, value: Double?), point: CGFloat) -> NSImage? {
        let img = s.value.flatMap { NSImage(systemSymbolName: s.name, variableValue: $0, accessibilityDescription: nil) } ?? NSImage(systemSymbolName: s.name, accessibilityDescription: nil)
        return img?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: point, weight: .semibold))
    }
    /// 等比缩放画进矩形并染色
    static func draw(_ img: NSImage?, in r: CGRect, color: NSColor) {
        guard let img, img.size.width > 0, img.size.height > 0 else { return }
        let k = min(r.width / img.size.width, r.height / img.size.height)
        let s = CGSize(width: img.size.width * k, height: img.size.height * k)
        let dst = CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height)
        let tinted = NSImage(size: s, flipped: false) { rr in img.draw(in: rr); color.set(); rr.fill(using: .sourceAtop); return true }
        tinted.draw(in: dst)
    }
    static func batteryColor(_ p: Int, charging: Bool) -> NSColor {
        p <= 10 ? .systemRed : (p <= 20 ? .systemOrange : (charging ? .systemGreen : NSColor(red: 0.18, green: 0.70, blue: 0.96, alpha: 1)))
    }
    /// 电池图标里画什么：数字（显示百分比时）和闪电（充电时，不论是否显示百分比、单色还是彩色）
    static func batteryMarks(charging: Bool, config c: TrioConfig) -> (number: Bool, bolt: Bool) { (c.percent, charging) }
    static func drawBattery(in r: CGRect, percent p: Int, charging: Bool, config c: TrioConfig, ink: NSColor) {
        let nub: CGFloat = 2.5, body = CGRect(x: r.minX + 0.5, y: r.minY + 1.5, width: r.width - nub - 1, height: r.height - 3)
        let radius = body.height * 0.28
        ink.withAlphaComponent(c.color ? 0.55 : 0.9).setStroke()
        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius); outline.lineWidth = 1; outline.stroke()
        ink.withAlphaComponent(c.color ? 0.55 : 0.9).setFill()
        NSBezierPath(roundedRect: CGRect(x: body.maxX + 1, y: r.midY - r.height * 0.14, width: nub - 1, height: r.height * 0.28), xRadius: 0.8, yRadius: 0.8).fill()
        let inner = body.insetBy(dx: 1.8, dy: 1.8)
        let fill = CGRect(x: inner.minX, y: inner.minY, width: max(2, inner.width * CGFloat(min(max(p, 0), 100)) / 100), height: inner.height)
        // 单色且要显示数字时，电量条画淡一些，数字压在上面才看得清
        (c.color ? batteryColor(p, charging: charging) : ink.withAlphaComponent(c.percent ? 0.32 : 0.9)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius * 0.6, yRadius: radius * 0.6).fill()
        let marks = batteryMarks(charging: charging, config: c)
        if marks.number {
            // 2.12：显示百分比时充电也要画闪电（单色模式只靠数字分不出是否在充电）。闪电放在数字左边，放不下就把字缩小
            let boltW = marks.bolt ? (body.height * 0.62).rounded(.down) : 0, gap: CGFloat = marks.bolt ? 0.5 : 0
            var fontSize = (r.height * 0.6).rounded()
            func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
                var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: c.color ? NSColor.white : ink]
                if c.color { a[.strokeColor] = NSColor.black.withAlphaComponent(0.35); a[.strokeWidth] = -2 }
                // 彩色模式下电量条不够长（低于 70%）时，白字会有一部分落在空白处看不见：改用墨色
                if c.color, p < 70 { a = [.font: a[.font]!, .foregroundColor: ink] }
                return a
            }
            var t = NSAttributedString(string: "\(p)", attributes: attrs(fontSize))
            while marks.bolt, fontSize > 6, t.size().width + gap + boltW > body.width - 2 {
                fontSize -= 0.5; t = NSAttributedString(string: "\(p)", attributes: attrs(fontSize))
            }
            let sz = t.size(), total = sz.width + gap + boltW, x0 = body.midX - total / 2
            if marks.bolt {
                let textInk = (attrs(fontSize)[.foregroundColor] as? NSColor) ?? ink
                draw(symbol(("bolt.fill", nil), point: body.height), in: CGRect(x: x0, y: body.minY + 1, width: boltW, height: body.height - 2), color: textInk)
            }
            t.draw(at: CGPoint(x: x0 + boltW + gap, y: body.midY - sz.height / 2))
        } else if marks.bolt {
            draw(symbol(("bolt.fill", nil), point: r.height * 0.6), in: body.insetBy(dx: 2, dy: 1.5), color: c.color ? .white : ink)
        }
    }
    /// 紧凑模式的 Wi-Fi：圆点 + 三道弧，亮几道表示几格信号；关闭时整体变淡并加斜线
    static func drawCompactWifi(_ w: WifiState, in r: CGRect, ink: NSColor) {
        let c = CGPoint(x: r.midX, y: r.minY + 1.2), maxR = min(r.height - 1.4, r.width / 2 / 0.72)
        let on = w.link == .connected, dim = ink.withAlphaComponent(0.28)
        (on || w.link == .disconnected ? (on ? ink : dim) : dim).setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - 1.1, y: c.y - 1.1, width: 2.2, height: 2.2)).fill()
        for i in 1...3 {
            let arc = NSBezierPath(); arc.lineWidth = max(1.3, r.height * 0.16); arc.lineCapStyle = .round
            arc.appendArc(withCenter: c, radius: maxR * CGFloat(i) / 3, startAngle: 46, endAngle: 134)
            (on && w.bars >= i ? ink : dim).setStroke(); arc.stroke()
        }
        if w.link == .off || w.link == .unavailable {
            let slash = NSBezierPath(); slash.lineWidth = 1.3; slash.lineCapStyle = .round
            slash.move(to: CGPoint(x: r.midX - maxR * 0.7, y: r.maxY - 0.8)); slash.line(to: CGPoint(x: r.midX + maxR * 0.7, y: r.minY + 0.8))
            ink.setStroke(); slash.stroke()
        }
    }
    /// 紧凑模式的音量：小喇叭 + 一条刻度，填充长度 = 音量；静音时刻度变淡并画叉
    static func drawCompactVolume(_ v: VolumeState, in r: CGRect, ink: NSColor) {
        let dim = ink.withAlphaComponent(0.28), h = min(r.height, 5.5), y = r.midY
        let cone = NSBezierPath()
        cone.move(to: CGPoint(x: r.minX, y: y - h * 0.22)); cone.line(to: CGPoint(x: r.minX + h * 0.35, y: y - h * 0.22))
        cone.line(to: CGPoint(x: r.minX + h * 0.8, y: y - h * 0.5)); cone.line(to: CGPoint(x: r.minX + h * 0.8, y: y + h * 0.5))
        cone.line(to: CGPoint(x: r.minX + h * 0.35, y: y + h * 0.22)); cone.line(to: CGPoint(x: r.minX, y: y + h * 0.22)); cone.close()
        ink.setFill(); cone.fill()
        let track = CGRect(x: r.minX + h * 0.8 + 2, y: y - 1.2, width: r.maxX - (r.minX + h * 0.8 + 2), height: 2.4)
        dim.setFill(); NSBezierPath(roundedRect: track, xRadius: 1.2, yRadius: 1.2).fill()
        if let l = v.level, !v.muted, l > 0.001 {
            ink.setFill(); NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(2.4, track.width * CGFloat(l)), height: track.height), xRadius: 1.2, yRadius: 1.2).fill()
        } else if v.level != nil {
            let x = NSBezierPath(); x.lineWidth = 1.2; x.lineCapStyle = .round
            let cx = track.midX, d = min(h * 0.42, 2.2)
            x.move(to: CGPoint(x: cx - d, y: y - d)); x.line(to: CGPoint(x: cx + d, y: y + d))
            x.move(to: CGPoint(x: cx - d, y: y + d)); x.line(to: CGPoint(x: cx + d, y: y - d))
            ink.setStroke(); x.stroke()
        }
    }
    /// 单色模式是模板图（跟随菜单栏深浅）；彩色模式按当前外观取墨色
    static func image(config: TrioConfig, battery: Int?, charging: Bool, wifi: WifiState, volume: VolumeState) -> NSImage {
        let c = config.sanitized(), layout = TrioLayout.make(c, hasBattery: battery != nil)
        let img = NSImage(size: layout.size, flipped: false) { _ in
            let ink: NSColor = c.color ? .labelColor : .black
            let stacked = (layout.frames[.wifi]?.height ?? layout.size.height) < layout.size.height
            if let r = layout.frames[.wifi] { stacked ? drawCompactWifi(wifi, in: r, ink: ink) : draw(symbol(wifiSymbol(wifi), point: r.height), in: r, color: ink) }
            if let r = layout.frames[.volume] { stacked ? drawCompactVolume(volume, in: r, ink: ink) : draw(symbol(volumeSymbol(volume), point: r.height), in: r, color: ink) }
            if let r = layout.frames[.battery], let p = battery { drawBattery(in: r, percent: p, charging: charging, config: c, ink: ink) }
            return true
        }
        img.isTemplate = !c.color
        return img
    }
    static func describe(battery: Int?, charging: Bool, wifi: WifiState, volume: VolumeState) -> String {
        [battery.map { "电池 \($0)%" + (charging ? "，已接电源" : "") }, wifi.summary, "音量 " + volume.text].compactMap { $0 }.joined(separator: "；")
    }
}

// MARK: - 设置
struct TrioSettings: View {
    @ObservedObject var model = TrioModel.shared
    @ObservedObject var m = Monitor.shared
    var body: some View {
        let c = model.config
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("预览").font(DS.sub()).foregroundColor(DS.text.secondary)
                Image(nsImage: TrioIcon.image(config: c, battery: m.s.battery ?? 80, charging: m.s.charging || m.s.onAC, wifi: model.wifi, volume: model.volume))
                    .renderingMode(c.color ? .original : .template).foregroundColor(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .accessibilityIdentifier("trio.preview").accessibilityLabel("合并状态图标预览")
                Spacer()
            }
            HStack(spacing: 14) {
                Text("显示").font(DS.sub()).frame(width: 34, alignment: .leading)
                ForEach(TrioItem.allCases, id: \.self) { i in
                    Toggle(i.title, isOn: Binding(get: { c.items.contains(i) }, set: { _ in model.config = c.toggled(i) }))
                        .toggleStyle(.checkbox).accessibilityIdentifier("trio.item." + i.rawValue)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Text("排列").font(DS.sub()).frame(width: 34, alignment: .leading)
                Picker("", selection: Binding(get: { c.compact }, set: { v in var n = c; n.compact = v; model.config = n })) {
                    Text("紧凑（Wi-Fi 与音量上下叠放）").tag(true); Text("并排").tag(false)
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 300).accessibilityIdentifier("trio.compact")
                Spacer()
            }
            HStack(spacing: 14) {
                Text("大小").font(DS.sub()).frame(width: 34, alignment: .leading)
                Picker("", selection: Binding(get: { c.size }, set: { v in var n = c; n.size = v; model.config = n })) {
                    Text("小").tag(0); Text("中").tag(1); Text("大").tag(2)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 150).accessibilityIdentifier("trio.size")
                Toggle("电池里显示百分比", isOn: Binding(get: { c.percent }, set: { v in var n = c; n.percent = v; model.config = n })).toggleStyle(.checkbox).accessibilityIdentifier("trio.percent")
                Toggle("电池按电量着色", isOn: Binding(get: { c.color }, set: { v in var n = c; n.color = v; model.config = n })).toggleStyle(.checkbox).accessibilityIdentifier("trio.color")
                Spacer()
            }
            HStack(spacing: 14) {
                Text("面板").font(DS.sub()).frame(width: 34, alignment: .leading)
                Toggle("显示音量和 Wi-Fi 控制", isOn: Binding(get: { c.panel }, set: { v in var n = c; n.panel = v; model.config = n })).toggleStyle(.checkbox).accessibilityIdentifier("trio.panel")
                Toggle("显示 Wi-Fi 名称（需要定位权限）", isOn: Binding(get: { c.wifiName }, set: { v in
                    var n = c; n.wifiName = v; model.config = n
                    if v, !MOTests.active { model.requestWifiName() }
                })).toggleStyle(.checkbox).accessibilityIdentifier("trio.wifiname")
                Spacer()
            }
            Text("要省出菜单栏空间，可以在「系统设置 › 控制中心」里把系统自带的 Wi-Fi、电池、声音图标设为不在菜单栏显示。")
                .font(.caption).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .onAppear { model.refresh() }
    }
}

// MARK: - 面板里的音量与 Wi-Fi
struct TrioPanelCard: View {
    @ObservedObject var model = TrioModel.shared
    var body: some View {
        let v = model.volume, w = model.wifi
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { model.toggleMute() }) {
                    Image(systemName: v.muted || v.waves == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                }.buttonStyle(.plain).foregroundColor(DS.text.secondary).disabled(v.level == nil)
                    .help(v.muted ? "取消静音" : "静音").accessibilityIdentifier("panel.trio.mute").accessibilityLabel(v.muted ? "取消静音" : "静音")
                if let l = v.level {
                    Slider(value: Binding(get: { v.muted ? 0 : l }, set: { model.setVolume($0) }), in: 0...1)
                        .controlSize(.small).disabled(!v.settable).accessibilityIdentifier("panel.trio.volume").accessibilityLabel("输出音量")
                    Text(v.text).font(DS.num(11)).foregroundColor(DS.text.secondary).frame(width: 44, alignment: .trailing)
                } else {
                    Text(v.text).font(DS.sub()).foregroundColor(DS.text.secondary); Spacer()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: w.link == .connected ? "wifi" : "wifi.slash").frame(width: 18).foregroundColor(DS.text.secondary).accessibilityHidden(true)
                Text(w.summary).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1).minimumScaleFactor(0.8).accessibilityIdentifier("panel.trio.wifi")
                Spacer()
            }
        }
        .padding(DS.tilePadding).frame(maxWidth: .infinity, alignment: .leading).card()
        .accessibilityElement(children: .contain).accessibilityIdentifier("panel.trio")
        .onAppear { model.refresh() }
    }
}
