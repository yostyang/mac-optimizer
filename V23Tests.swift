import Foundation
import SwiftUI
import AppKit

final class V23Gamma: GammaSystem {
    var changed: [CGDirectDisplayID] = []
    var restored: [CGDirectDisplayID] = []
    var failRestore = false
    func set(_ id: CGDirectDisplayID, r: Double, g: Double, b: Double) -> Bool { changed.append(id); return true }
    func restore() {}
    func restore(_ id: CGDirectDisplayID) -> Bool { if failRestore { return false }; restored.append(id); return true }
}
final class V23DDC: DDCChannel {
    var value = 60
    var failWrite = false
    var ignoreWrite = false
    var readDelay: UInt32 = 0
    var caps = "(vcp(10 14(05 08) DC(00 02)))"
    var writes: [Int] = []
    func read(_ code: UInt8) -> (value: Int, max: Int)? { if readDelay > 0 { usleep(readDelay) }; return (value, 100) }
    func write(_ code: UInt8, _ value: Int) -> Bool { writes.append(value); if !failWrite && !ignoreWrite { self.value = value }; return !failWrite }
    func capabilities() -> String { caps }
}
final class V23Profiles: DisplayProfileSystem {
    let a = URL(fileURLWithPath: "/tmp/display-original.icc"), b = URL(fileURLWithPath: "/tmp/display-custom.icc")
    var values: [CGDirectDisplayID: URL] = [:]
    var fail = false
    var ignores = false
    var calls: [(CGDirectDisplayID, URL?)] = []
    func read(_ id: CGDirectDisplayID) -> DisplayProfileState {
        DisplayProfileState(current: values[id] ?? a, overrideURL: values[id], choices: [DisplayProfile(name: "Original", url: a), DisplayProfile(name: "Custom", url: b)], factoryDefault: a)
    }
    func apply(_ id: CGDirectDisplayID, url: URL?) -> Bool {
        calls.append((id, url)); if !fail && !ignores { values[id] = url }; return !fail
    }
}
extension MOTests {
    static func v23UI(_ window: NSWindow) {
        sec("2.3 色彩入口完整流程（模拟设备）")
        let original = DisplayManager.shared
        let (manager, _, _, _) = v15Fixtures()
        DisplayManager.shared = manager
        defer { DisplayManager.shared = original; Nav.shared.sel = .monitor }
        Nav.shared.sel = .monitor; settle(0.2); Nav.shared.sel = .display; settle(0.5)
        if let button = find(window.contentView!, id: "disp.tab.1") { button.press() }
        check(waitUntil(2) { find1(window.contentView!, id: "disp.icc") != nil && find1(window.contentView!, id: "disp.color.8") != nil }, "色彩标签显示ICC与真实硬件预设")
        check(find1(window.contentView!, id: "disp.color.1") == nil, "不显示设备未声明的sRGB选项")
        if let button = find(window.contentView!, id: "disp.color.8") { button.press() }
        check(waitUntil(3) { manager.ddc[3]?.colorPreset == 8 && manager.ddcPending.isEmpty }, "点击硬件色彩选项，等待实际回读")
        if let button = find(window.contentView!, id: "disp.color.restore") { button.press() }
        check(waitUntil(3) { manager.ddc[3]?.colorPreset == 5 && manager.ddcPending.isEmpty }, "界面恢复原硬件色彩并回读")
        let blocked = MockDDC(); blocked.ignoreWrite = true; manager.channels = { _ in blocked }
        if let button = find(window.contentView!, id: "disp.mode.2") { button.press() }
        check(waitUntil(3) {
            guard manager.ddcPending.isEmpty, manager.isIncompatible(manager.displays[0], .displayMode, 2),
                  let button = find1(window.contentView!, id: "disp.mode.2") else { return false }
            return axString(button.o, "accessibilityLabel").contains("上次写入未生效")
        }, "写入未生效时界面与朗读提示兼容性")
        blocked.ignoreWrite = false
        if let button = find(window.contentView!, id: "disp.mode.2") { button.press() }
        check(waitUntil(3) {
            guard manager.ddcPending.isEmpty, !manager.isIncompatible(manager.displays[0], .displayMode, 2),
                  let button = find1(window.contentView!, id: "disp.mode.2") else { return false }
            return !axString(button.o, "accessibilityLabel").contains("上次写入未生效")
        }, "重试成功后界面移除兼容性提示")
        fits(window.contentView!, "色彩页默认窗口")
    }
    static func v23Snapshots(_ out: String) {
        let old = DisplayManager.shared
        let (manager, _, _, _) = v15Fixtures(); DisplayManager.shared = manager
        defer { DisplayManager.shared = old }
        let mon = Monitor.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            var snapshot = fixture(); snapshot.batteryVoltageV = 12.8; snapshot.batteryCurrentA = 2
            snapshot.batteryInputWatts = 65; snapshot.batteryAdapterWatts = 100
            let views: [(AnyView, String)] = [
                (AnyView(DisplayPage(colorTab: true).frame(height: Layout.minSize.height)), "display-color-min"),
                (AnyView(BatteryPage(m: mon).powerTab(snapshot).padding(20)), "power-charging")
            ]
            for (view, tag) in views {
                let host = NSHostingView(rootView: view.frame(width: Layout.minSize.width - 212).background(pageBG))
                let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance); window.contentView = host; window.orderFrontRegardless(); settle(0.6)
                if let bitmap = pngRep(host, out + "/" + tag + "-" + name + ".png") { contrast(host, bitmap, tag + " " + name) }
                fits(host, tag + " " + name); window.orderOut(nil)
            }
        }
    }
    static func v23Tests() {
        sec("2.3 电池遥测与供电状态")
        var s = Snapshot(); s.battery = 84; s.onAC = true
        let properties: [String: Any] = ["Voltage": 12_800, "InstantAmperage": 0, "Amperage": 1000,
            "PowerTelemetryData": ["SystemPowerIn": 21_800], "AdapterDetails": ["Watts": 100]]
        PowerTelemetry.apply(properties, adapter: nil, to: &s)
        var flow = PowerFlowCalc.fromSnapshot(s)
        check(flow.inputWatts == 21.8 && flow.systemWatts == 21.8 && !flow.charging, "接电停充显示真实 DC 输入及系统估算")
        check(flow.adapterRatedWatts == 100 && flow.currentA == 0, "上报功率单列，瞬时电流0不回退旧平均电流")
        s.batteryCurrentA = 2; s.charging = false; s.batteryInputWatts = 80
        flow = PowerFlowCalc.fromSnapshot(s)
        check(flow.charging && flow.chargeWatts == 25.6 && abs((flow.systemWatts ?? 0) - 54.4) < 0.001, "电流已充入但充电标志滞后，按物理充电方向处理")
        s.batteryCurrentA = -2; s.charging = true; s.batteryInputWatts = 20
        flow = PowerFlowCalc.fromSnapshot(s)
        check(!flow.charging && flow.dischargeWatts == 25.6 && flow.systemWatts == 45.6 && flow.supplyText.contains("放电"), "接电补充放电：输入加电池贡献，不受旧充电标志误导")
        s.onAC = false; PowerTelemetry.apply(properties, adapter: ["Watts": 140], to: &s)
        check(s.batteryInputWatts == nil && s.batteryAdapterWatts == nil && PowerFlowCalc.fromSnapshot(s).inputWatts == nil, "拔电后忽略残留输入与适配器信息")
        PowerTelemetry.apply([:], adapter: nil, to: &s)
        check(s.batteryVoltageV == nil && s.batteryCurrentA == nil, "缺字段时清除前一次读数")
        check(PowerTelemetry.current(NSNumber(value: UInt64.max - 1999)) == -2 && PowerTelemetry.current(Double.infinity) == nil, "无符号补码与无效电流解码")
        s.onAC = true; s.charging = false; PowerTelemetry.apply(properties, adapter: ["Watts": 140], to: &s)
        check(s.batteryAdapterWatts == 140, "公开适配器信息优先，SmartBattery作为后备")
        s.batteryCurrentA = 3; s.batteryInputWatts = 10
        check(PowerFlowCalc.fromSnapshot(s).systemWatts == nil, "输入小于充电功率时不凑0W")
        s.batteryCurrentA = nil
        check(PowerFlowCalc.fromSnapshot(s).systemWatts == nil, "没有电池电流时不假定电池功率为0")
        s.batteryPowerUpdated = Date().addingTimeInterval(-60)
        check(PowerFlowCalc.fromSnapshot(s).inputWatts == nil && PowerFlowCalc.fromSnapshot(s).voltageV == nil && PowerFlowCalc.fromSnapshot(s).inputNote.contains("过期"), "过期遥测不展示为实时读数")
        s.batteryPowerUpdated = Date(); s.batteryCurrentA = 0; s.batteryFullyCharged = true
        check(PowerFlowCalc.fromSnapshot(s).supplyText.contains("已充满"), "系统已充满标志独立于百分比")

        sec("2.3 多屏隔离与写入回读")
        let displays = MockDisplays(); var second = displays.list[0]; second.id = 4; second.name = "Second Display"; displays.list.append(second)
        let gamma = V23Gamma(), manager = DisplayManager(sys: displays, gamma: gamma)
        manager.offline = true; manager.settings = DisplaySettings(); manager.refresh(); manager.conflict = ""
        let first = V23DDC(), other = V23DDC()
        manager.channels = { $0.id == 3 ? first : other }
        var done = false; manager.probeDDC { done = true }
        check(waitUntil(3) { done } && manager.ddc[3]?.caps.values[0x14] == [5, 8], "解析并读取真实列出的硬件色彩选项")
        manager.select(3); manager.setGamma(on: true); manager.setKelvin(3600)
        check(!gamma.changed.isEmpty && gamma.changed.allSatisfy { $0 == 3 }, "软件色温只应用于当前屏幕")
        manager.select(4); check(!manager.settings.gammaOn && manager.settings.kelvin == 6500, "第二台屏幕有独立默认设置")
        manager.select(3); check(manager.settings.gammaOn && manager.settings.kelvin == 3600, "切回屏幕保留自己的设置")
        gamma.failRestore = true; manager.setGamma(on: false)
        check(manager.settings.gammaOn && manager.gammaNotes[3]?.contains("未能恢复") == true, "恢复Gamma失败保留开启状态并说明")
        gamma.failRestore = false
        manager.setGamma(on: false); check(gamma.restored == [3], "关闭色温仅恢复目标屏幕")
        manager.setDDC(3, .brightness, 30); manager.setDDC(3, .brightness, 35); manager.setDDC(4, .brightness, 75)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && first.writes == [35] && other.writes == [75], "两屏同时调同一功能互不取消，同屏拖动合并")
        check(manager.ddc[3]?.brightness == 35 && manager.ddc[4]?.brightness == 75, "写后回读更新真实状态")
        first.failWrite = true; manager.setDDC(3, .brightness, 90)
        check(manager.ddc[3]?.brightness == 35, "请求发出不先冒充成功")
        check(waitUntil(3) { manager.ddcPending.isEmpty } && manager.ddc[3]?.brightness == 35 && manager.ddcNotes[3]?.contains("未确认") == true, "写入失败回显实际读数与原因")
        first.failWrite = false; first.ignoreWrite = true; manager.setDDC(3, .brightness, 90)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && manager.ddc[3]?.brightness == 35 && manager.ddcNotes[3]?.contains("未确认") == true, "发送成功但回读不符不称成功")
        first.ignoreWrite = false
        let count = first.writes.count; manager.setDDC(3, .colorPreset, 1); settle(0.3)
        check(first.writes.count == count, "未声明的sRGB选项不能写入")
        manager.setDDC(3, .colorPreset, 8)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && manager.ddc[3]?.colorPreset == 8, "硬件色彩预设切换回读")
        manager.restoreColor(3)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && first.value == 35, "硬件色彩恢复第一次修改前读数")
        manager.setDDC(3, .brightness, 99); manager.refresh(); settle(0.4)
        check(!first.writes.contains(99), "刷新/重连使旧排队写入失效")
        first.readDelay = 350_000
        manager.setDDC(3, .brightness, 55)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { manager.refresh() }
        settle(0.9); first.readDelay = 0
        check(!first.writes.contains(55), "读取旧值期间刷新，写入前再次核对连接代次")
        check(DDCCaps.parse("(vcp(14(05\n08) DC(00\t02)))").values[0xdc] == [0, 2], "能力字符串换行和制表符")

        sec("2.9 DDC 声明支持但拒绝写入")
        first.ignoreWrite = true; manager.setDDC(3, .displayMode, 2)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && manager.isIncompatible(displays.list[0], .displayMode, 2), "写入后读到原值才标记不兼容")
        check(!manager.isIncompatible(displays.list[1], .displayMode, 2), "兼容性记录按显示器隔离")
        first.ignoreWrite = false; manager.setDDC(3, .displayMode, 2)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && !manager.isIncompatible(displays.list[0], .displayMode, 2), "重试成功后清除不兼容提示")
        first.ignoreWrite = true; manager.setDDC(3, .displayMode, 0)
        check(waitUntil(3) { manager.ddcPending.isEmpty } && manager.isIncompatible(displays.list[0], .displayMode, 0), "其他值可单独记录")
        first.caps = "(vcp(10 14(05 08) DC(00 02 03)))"
        manager.probeDDC { done = true }
        check(waitUntil(3) { manager.ddc[3]?.caps.values[0xdc] == [0, 2, 3] } && !manager.isIncompatible(displays.list[0], .displayMode, 0), "能力列表变化后清除旧兼容性记录")

        sec("2.3 ICC 操作与恢复")
        let profileName = "mo-profile-" + UUID().uuidString + ".icc"
        let profileFile = URL(fileURLWithPath: "/private/tmp/" + profileName)
        try? Data().write(to: profileFile)
        defer { try? FileManager.default.removeItem(at: profileFile) }
        check(DisplayProfile.sameURL(URL(fileURLWithPath: "/tmp/" + profileName), profileFile), "ICC回读识别系统规范化的同一文件路径")
        let profiles = V23Profiles(); manager.profileSystem = profiles; manager.refreshProfiles()
        check(waitUntil(2) { manager.profileStates[3]?.current == profiles.a }, "读取各屏幕当前ICC")
        manager.setProfile(3, url: profiles.b)
        check(waitUntil(3) { manager.profileBusy.isEmpty } && profiles.values[3] == profiles.b && profiles.values[4] == nil, "ICC切换仅作用目标屏幕且回读")
        manager.restoreProfile(3)
        check(waitUntil(3) { manager.profileBusy.isEmpty } && profiles.values[3] == nil && manager.originalProfiles[displays.list[0].key] == nil, "恢复原来没有覆盖的ICC状态")
        profiles.fail = true; manager.setProfile(3, url: profiles.b)
        check(waitUntil(3) { manager.profileBusy.isEmpty } && manager.profileStates[3]?.current == profiles.a && manager.profileNotes[3]?.contains("未确认") == true, "ICC失败不先选中未生效项")
        profiles.fail = false; profiles.ignores = true; manager.setProfile(3, url: profiles.b)
        check(waitUntil(3) { manager.profileBusy.isEmpty } && manager.profileNotes[3]?.contains("未确认") == true, "ICC回读不符保留恢复入口")

        profiles.ignores = false
        let customManager = DisplayManager(sys: displays, gamma: V23Gamma()); customManager.offline = true
        customManager.profileSystem = profiles; customManager.refresh()
        profiles.values[3] = profiles.b; customManager.refreshProfiles()
        _ = waitUntil(2) { customManager.profileStates[3]?.current == profiles.b }
        customManager.setProfile(3, url: profiles.a)
        _ = waitUntil(3) { customManager.profileBusy.isEmpty }
        customManager.restoreProfile(3)
        check(waitUntil(3) { customManager.profileBusy.isEmpty } && profiles.values[3] == profiles.b, "已有自定义ICC时恢复原文件，不错误清除为厂商默认")

        sec("2.3 外设有效值和身份")
        let device = BTDevice(name: "Keyboard", address: "AA-BB", kind: "keyboard", connected: true, ble: false, percent: nil)
        let classic = BTParse.merge(paired: [device], ioreg: [:], gatt: [:], gattIssue: nil, classic: ["aa:bb": 72])
        check(classic.first?.percent == 72 && classic.first?.source == "系统经典蓝牙读数", "按地址合并经典蓝牙有效电量")
        let unknown = BTParse.merge(paired: [device], ioreg: [:], gatt: [:], gattIssue: nil, classic: ["aa:bb": 0])
        check(unknown.first?.percent == nil && unknown.first?.reason.contains("未取得") == true, "经典蓝牙0值保持未知")
        var twin = device; twin.address = "CC-DD"
        let duplicates = BTParse.merge(paired: [device, twin], ioreg: ["Keyboard": 80], gatt: ["Keyboard": 90], gattIssue: nil)
        check(duplicates.allSatisfy { $0.percent == nil }, "同名设备不按名称猜测电量归属")
        var identity = displays.list[0]; identity.vendor = 100; identity.model = 200
        let fakeService = AVServiceDDC("mock" as CFString); fakeService.vendor = 100; fakeService.model = 200
        check(DDCIdentity.match(identity, in: [fakeService], displays: [identity]) != nil, "显示器按EDID身份匹配")
        var identical = identity; identical.id = 9
        check(DDCIdentity.match(identity, in: [fakeService], displays: [identity, identical]) == nil, "相同型号无唯一身份时不猜测通道")
        manager.shutdown()
    }
}
