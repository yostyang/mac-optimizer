// 2.11 测试：菜单栏合并状态图标
import SwiftUI
import AppKit

final class FakeTrioSource: TrioSource {
    var w = WifiState(link: .connected, rssi: -58, name: "Home-5G")
    var v = VolumeState(level: 0.5, muted: false, settable: true)
    var askedName: [Bool] = []
    func wifi(withName: Bool) -> WifiState { askedName.append(withName); var x = w; if !withName { x.name = nil }; return x }
    func volume() -> VolumeState { v }
    func setVolume(_ x: Double) { v.level = x }
    func setMuted(_ m: Bool) { v.muted = m }
}

/// 截图用：各种设置下的图标（供人工查看）
struct TrioGallery: View {
    static let wifi = WifiState(link: .connected, rssi: -64, name: nil), vol = VolumeState(level: 0.6, muted: false, settable: true)
    static func cfg(_ f: (inout TrioConfig) -> Void) -> TrioConfig { var c = TrioConfig(); f(&c); return c }
    static let rows: [(String, TrioConfig, Int, Bool, WifiState, VolumeState)] = [
        ("默认：并排 · 中 · 彩色", TrioConfig(), 84, false, wifi, vol),
        ("默认 · 充电中", TrioConfig(), 84, true, wifi, vol),
        ("默认 · 低电量 · 信号弱 · 音量小", TrioConfig(), 12, false, WifiState(link: .connected, rssi: -88), VolumeState(level: 0.2, muted: false, settable: true)),
        ("单色", cfg { $0.color = false }, 84, false, wifi, vol),
        ("紧凑 · 彩色", cfg { $0.compact = true }, 84, false, wifi, vol),
        ("紧凑 · 单色", cfg { $0.compact = true; $0.color = false }, 84, false, wifi, vol),
        ("不显示百分比 · 充电中", cfg { $0.percent = false }, 55, true, wifi, vol),
        ("小", cfg { $0.size = 0 }, 84, false, wifi, vol),
        ("大", cfg { $0.size = 2 }, 100, false, wifi, vol),
        ("只有 Wi-Fi 和电池", cfg { $0.items = [.wifi, .battery] }, 84, false, wifi, vol),
        ("只有音量和电池", cfg { $0.items = [.volume, .battery] }, 84, false, wifi, vol),
        ("紧凑 · Wi-Fi 关闭 · 静音", cfg { $0.compact = true }, 47, false, WifiState(link: .off), VolumeState(level: 0.5, muted: true, settable: true)),
        ("未连接 · 输出设备不能调音量", TrioConfig(), 47, false, WifiState(link: .disconnected), VolumeState()),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 12) {
                    Image(nsImage: TrioIcon.image(config: r.1, battery: r.2, charging: r.3, wifi: r.4, volume: r.5))
                        .renderingMode(r.1.color ? .original : .template).foregroundColor(.primary)
                        .frame(width: 90, height: 24).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                    Text(r.0).font(DS.sub())
                    Spacer()
                }
            }
        }.padding(14).frame(width: 360)
    }
}

enum V211 {
    typealias T = MOTests
    static func tests() {
        T.sec("2.11 合并状态图标：设置")
        var c = TrioConfig()
        T.check(c.items == [.wifi, .volume, .battery] && !c.compact && c.percent && c.color && c.size == 1 && c.panel && !c.wifiName, "默认：三项都显示、并排、中号、彩色电池，不读 Wi-Fi 名称")
        c = c.toggled(.volume); T.check(c.items == [.wifi, .battery], "可以关掉其中一项")
        c = c.toggled(.wifi).toggled(.battery); T.check(c.items == [.battery], "至少保留一项")
        c = c.toggled(.wifi); T.check(c.items == [.wifi, .battery], "重新打开后顺序固定为 Wi-Fi、音量、电池")
        var odd = TrioConfig(); odd.items = []; odd.size = 9
        T.check(odd.sanitized().items == [.battery] && odd.sanitized().size == 2, "异常设置会被修正")
        let suite = "mo.test.trio.\(getpid())", ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        T.check(TrioConfig.load(ud) == TrioConfig(), "没有保存过时用默认设置")
        var saved = TrioConfig(); saved.compact = true; saved.color = false; saved.size = 2; saved.items = [.volume, .battery]; saved.save(ud)
        T.check(TrioConfig.load(ud) == saved, "设置可保存读取")
        ud.removePersistentDomain(forName: suite)

        T.sec("2.11 合并状态图标：读数与图形")
        T.check(WifiState.bars(rssi: -45) == 3 && WifiState.bars(rssi: -60) == 3 && WifiState.bars(rssi: -66) == 2 && WifiState.bars(rssi: -80) == 1 && WifiState.bars(rssi: -90) == 0, "信号强度换算成 0–3 格")
        T.check(WifiState(link: .off, rssi: -40).bars == 0 && WifiState(link: .disconnected).bars == 0, "关闭或未连接时没有信号格")
        T.check(WifiState(link: .connected, rssi: -58, name: "Home-5G").summary == "Home-5G · 信号强（-58 dBm）" && WifiState(link: .connected, rssi: -75).summary == "已连接 · 信号弱（-75 dBm）", "Wi-Fi 说明：有名称显示名称，没有就写已连接")
        T.check(WifiState(link: .off).summary == "Wi-Fi 已关闭" && WifiState(link: .disconnected).summary == "未连接 Wi-Fi", "Wi-Fi 关闭与未连接分开说明")
        T.check(VolumeState(level: 0, muted: false, settable: true).waves == 0 && VolumeState(level: 0.2).waves == 1 && VolumeState(level: 0.5).waves == 2 && VolumeState(level: 1).waves == 3 && VolumeState(level: 0.8, muted: true).waves == 0, "音量换算成 0–3 档，静音为 0")
        T.check(VolumeState(level: 0.426).text == "43%" && VolumeState(level: 0.5, muted: true).text == "已静音" && VolumeState().text == "此输出设备不支持调节", "音量文字")
        T.check(TrioIcon.wifiSymbol(WifiState(link: .off)).name == "wifi.slash" && TrioIcon.wifiSymbol(WifiState(link: .connected, rssi: -50)) == ("wifi", 1) && TrioIcon.wifiSymbol(WifiState(link: .disconnected)) == ("wifi", 0), "Wi-Fi 图形随状态变化")
        T.check(TrioIcon.volumeSymbol(VolumeState(level: 0.5, muted: true)).name == "speaker.slash.fill" && TrioIcon.volumeSymbol(VolumeState(level: 0.9)).name == "speaker.wave.3.fill" && TrioIcon.volumeSymbol(VolumeState()).name == "speaker.fill", "音量图形随状态变化")
        T.check(TrioIcon.describe(battery: 84, charging: true, wifi: WifiState(link: .off), volume: VolumeState(level: 0.3)) == "电池 84%，已接电源；Wi-Fi 已关闭；音量 30%", "鼠标停留时的文字说明")

        T.sec("2.11 合并状态图标：布局")
        func noOverlap(_ l: TrioLayout) -> Bool {
            let rs = Array(l.frames.values), bounds = CGRect(origin: .zero, size: l.size)
            for i in rs.indices { if !bounds.insetBy(dx: -0.01, dy: -0.01).contains(rs[i]) { return false }; for j in rs.indices where j > i { if rs[i].intersects(rs[j]) { return false } } }
            return true
        }
        var compactCfg = TrioConfig(); compactCfg.compact = true
        let compact = TrioLayout.make(compactCfg, hasBattery: true)
        T.check(compact.size.height == 16 && compact.frames.count == 3 && noOverlap(compact), "紧凑：三项互不重叠且不超出图标", "\(compact.size)")
        T.check(compact.frames[.wifi]!.minX == compact.frames[.volume]!.minX && compact.frames[.wifi]!.minY > compact.frames[.volume]!.maxY - 0.01 && compact.frames[.battery]!.minX > compact.frames[.wifi]!.maxX, "紧凑：Wi-Fi 在上、音量在下，电池在右")
        var rowCfg = TrioConfig(); rowCfg.compact = false
        let row = TrioLayout.make(rowCfg, hasBattery: true)
        T.check(noOverlap(row) && row.size.width > compact.size.width && row.frames[.wifi]!.maxX < row.frames[.volume]!.minX && row.frames[.volume]!.maxX < row.frames[.battery]!.minX, "并排：从左到右 Wi-Fi、音量、电池，比紧凑宽", "\(Int(row.size.width)) 对 \(Int(compact.size.width))")
        for s in 0...2 { var x = TrioConfig(); x.size = s; x.compact = true; let l = TrioLayout.make(x, hasBattery: true); T.check(l.size.height == TrioLayout.heights[s] && l.size.height <= 18 && noOverlap(l), "大小 \(["小", "中", "大"][s])：高 \(Int(l.size.height)) pt，放得进菜单栏") }
        var two = TrioConfig(); two.compact = true; two.items = [.wifi, .battery]
        let l2 = TrioLayout.make(two, hasBattery: true)
        T.check(l2.frames[.volume] == nil && l2.frames[.wifi]!.height == 16 && l2.size.width < row.size.width, "关掉音量后 Wi-Fi 用整格高度，图标变窄")
        let desktop = TrioLayout.make(compactCfg, hasBattery: false)
        T.check(desktop.frames[.battery] == nil && desktop.frames.count == 2 && noOverlap(desktop), "没有电池的 Mac：只画 Wi-Fi 和音量")
        var only = TrioConfig(); only.items = [.battery]
        T.check(TrioLayout.make(only, hasBattery: false).frames.count == 1, "只选了电池但机器没有电池：退回显示音量，不出现空图标")
        var mono = compactCfg; mono.color = false
        let img = TrioIcon.image(config: mono, battery: 84, charging: false, wifi: WifiState(link: .connected, rssi: -60), volume: VolumeState(level: 0.5))
        T.check(img.size == compact.size && img.isTemplate && !TrioIcon.image(config: TrioConfig(), battery: 84, charging: false, wifi: WifiState(), volume: VolumeState()).isTemplate, "单色图标是模板图（跟随菜单栏深浅），彩色不是")

        T.sec("2.11 合并状态图标：音量与 Wi-Fi 控制")
        let m = TrioModel(); m.persist = false
        let src = FakeTrioSource(); m.source = src
        m.config = TrioConfig()
        T.check(m.wifi.link == .connected && m.wifi.name == nil && src.askedName.allSatisfy { !$0 }, "默认不读取 Wi-Fi 名称")
        var named = TrioConfig(); named.wifiName = true; m.config = named
        T.check(m.wifi.name == "Home-5G" && src.askedName.last == true, "打开「显示 Wi-Fi 名称」后才读取")
        m.setVolume(0.8); T.check(src.v.level == 0.8 && m.volume.level == 0.8, "拖动滑块设置音量")
        m.toggleMute(); T.check(src.v.muted && m.volume.muted && m.volume.waves == 0, "点喇叭静音")
        m.setVolume(0.3); T.check(!src.v.muted && m.volume.level == 0.3, "静音时调音量会取消静音")
        m.toggleMute(); m.toggleMute(); T.check(!m.volume.muted, "再点一次取消静音")
    }

    static func ui(_ w: NSWindow) {
        T.sec("2.11 设置页：合并状态图标")
        let alerts = BatteryAlerts.shared, keepMode = alerts.settings.menuIndicator
        let model = TrioModel.shared, keepConfig = model.config, keepSource = model.source, keepPersist = model.persist
        model.persist = false; model.source = FakeTrioSource(); model.config = TrioConfig()
        defer { alerts.settings.menuIndicator = keepMode; model.config = keepConfig; model.source = keepSource; model.persist = keepPersist; Nav.shared.sel = .monitor }
        let pv = w.contentView!
        alerts.settings.menuIndicator = "cpu"
        Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .settings; T.settle(0.6)
        T.check(T.find1(pv, id: "trio.preview") == nil, "没选「合并状态」时不显示它的设置")
        alerts.settings.menuIndicator = "trio"
        T.check(T.waitUntil(2) { T.find1(pv, id: "trio.preview") != nil }, "选「合并状态」后出现预览和设置")
        T.find(pv, id: "trio.item.volume")?.press()
        T.check(T.waitUntil(2) { model.config.items == [.wifi, .battery] }, "取消勾选「音量」后图标只剩 Wi-Fi 和电池", "\(model.config.items)")
        T.find(pv, id: "trio.color")?.press()
        T.check(T.waitUntil(2) { !model.config.color }, "取消「电池按电量着色」后变为单色")
        T.find(pv, id: "trio.panel")?.press()
        T.check(T.waitUntil(2) { !model.config.panel }, "可关闭面板里的音量和 Wi-Fi 控制")
    }
}
