// 2.17 测试：输入/输出设备切换与自定义快捷键
import AppKit
import CoreAudio
import Carbon

enum V217 {
    typealias T = MOTests
    static let out3 = [
        AudioDeviceInfo(id: 1, uid: "a", name: "内建扬声器"),
        AudioDeviceInfo(id: 2, uid: "b", name: "显示器"),
        AudioDeviceInfo(id: 3, uid: "c", name: "耳机"),
    ]

    static func tests() {
        T.sec("2.17 音频设备：枚举与轮换")
        T.check(AudioDevices.next(out3, current: 1) == 2 && AudioDevices.next(out3, current: 3) == 1, "轮换到下一个，末尾回到第一个")
        T.check(AudioDevices.next(out3, current: nil) == 1 && AudioDevices.next(out3, current: 99) == 1, "没有默认或默认不在列表里时切到第一个")
        T.check(AudioDevices.next([], current: 1) == nil && AudioDevices.next([out3[0]], current: 1) == 1, "空列表不变，单设备轮换还是自己")
        let outs = AudioDevices.devices(input: false)
        T.check(outs.allSatisfy { !$0.name.isEmpty }, "输出设备都有名称", outs.map(\.name).joined(separator: ", "))
        if let d = AudioDevices.defaultDevice(input: false) {
            T.check(outs.contains { $0.id == d }, "默认输出设备在输出列表里")
        } else { T.check(true, "这台机器没有默认输出设备") }
        // 默认设备 id 不在枚举列表里（刚被拔掉等竞态）——显示未取得，不冒充某个设备名
        let gone = TrioModel(); gone.persist = false
        let gsrc = FakeTrioSource(); gsrc.outs = out3; gsrc.dout = 99
        gone.source = gsrc; gone.config = TrioConfig()
        T.check(gone.outputName == "未取得", "默认设备不在列表里时写未取得", gone.outputName)

        T.sec("2.17 音频设备：模型切换")
        let m = TrioModel(); m.persist = false
        let src = FakeTrioSource()
        src.outs = out3; src.dout = 1
        src.ins = [AudioDeviceInfo(id: 7, uid: "m1", name: "内建麦克风"), AudioDeviceInfo(id: 8, uid: "m2", name: "耳机麦克风")]
        src.din = 7
        m.source = src; m.config = TrioConfig()
        T.check(m.outputs == out3 && m.inputs.count == 2 && m.outputName == "内建扬声器" && m.inputName == "内建麦克风", "刷新后读到设备列表与默认名称")
        T.check(m.cycleOutput() == 2 && src.dout == 2 && m.outputName == "显示器", "快捷键轮换切到下一个输出")
        T.check(m.cycleOutput() == 3 && m.cycleOutput() == 1, "末尾轮换回第一个")
        m.setInput(8); T.check(src.din == 8 && m.inputName == "耳机麦克风", "菜单直接选择输入设备")
        T.check(m.cycleInput() == 7 && src.din == 7, "输入快捷键轮换到下一个")
        m.toggleMic(); T.check(src.mic && m.micMuted, "麦克风静音")
        m.toggleMic(); T.check(!m.micMuted, "再按一次取消静音")
        src.outs = []; src.dout = nil
        m.refresh()
        T.check(m.outputs.isEmpty && m.outputName == "没有输出设备" && m.cycleOutput() == nil, "输出设备全部拔掉后列表为空、轮换不动")

        T.sec("2.17 快捷键：槽位存储与文字")
        let suite = "mo.test.hk.\(getpid())", d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        T.check(HotKeySlot.micMute.stored(in: d) == nil && HotKeySlot.outputNext.stored(in: d) == nil, "音频快捷键默认未设置")
        T.check(HotKeySlot.palette.stored(in: d)?.code == CommandPalette.defCode && HotKeySlot.palette.stored(in: d)?.mods == CommandPalette.defMods, "命令面板默认 ⌥Space")
        HotKeySlot.micMute.save(code: 46, mods: UInt32(optionKey), in: d)
        T.check(HotKeySlot.micMute.stored(in: d)?.code == 46 && HotKeySlot.micMute.label(in: d) == "⌥M", "录制后保存读取，字母键显示正确", HotKeySlot.micMute.label(in: d))
        HotKeySlot.outputNext.save(code: 49, mods: UInt32(optionKey | controlKey), in: d)
        T.check(HotKeySlot.outputNext.label(in: d) == "⌃⌥Space", "多修饰键按 ⌃⌥⇧⌘ 顺序显示", HotKeySlot.outputNext.label(in: d))
        HotKeySlot.micMute.clear(in: d)
        T.check(HotKeySlot.micMute.stored(in: d) == nil && HotKeySlot.micMute.label(in: d) == "未设置", "清除后回到未设置")
        d.removePersistentDomain(forName: suite)
        T.check(CommandPalette.label(code: 46, mods: UInt32(optionKey)) == "⌥M" && CommandPalette.label(code: 49, mods: UInt32(optionKey)) == "⌥Space", "键位文字表")
        T.check(HotKeySlot.palette.hkID != HotKeySlot.micMute.hkID && HotKeySlot.micMute.hkID != HotKeySlot.outputNext.hkID && HotKeySlot.outputNext.hkID != HotKeySlot.inputNext.hkID, "四个槽位的 Carbon 热键 id 互不相同")
    }

    static func ui(_ w: NSWindow) {
        T.sec("2.17 设置页：快捷键列表")
        let pv = w.contentView!
        Nav.shared.sel = .settings; T.settle(0.6)
        defer { Nav.shared.sel = .monitor }
        T.check(T.waitUntil(2) { T.find1(pv, id: "set.hotkey.palette") != nil }, "命令面板快捷键行")
        T.check(T.find1(pv, id: "set.hotkey.mic-mute") != nil && T.find1(pv, id: "set.hotkey.output-next") != nil && T.find1(pv, id: "set.hotkey.input-next") != nil, "三个音频快捷键行都在设置页")
    }
}
