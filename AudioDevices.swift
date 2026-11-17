// 2.17：输入 / 输出音频设备切换 + 可自定义的全局快捷键
// 只用公开 API：CoreAudio 枚举设备与读写默认设备；Carbon RegisterEventHotKey 注册热键（不需要辅助功能权限）。
// 设备列表与「下一个」轮换是纯逻辑，可注入测试；实际切换走 TrioModel。
import Foundation
import CoreAudio
import AudioToolbox
import Carbon

// MARK: - 设备枚举（纯系统读写）
struct AudioDeviceInfo: Equatable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func globalAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    static var defaultInputAddr = globalAddr(kAudioHardwarePropertyDefaultInputDevice)
    static var defaultOutputAddr = globalAddr(kAudioHardwarePropertyDefaultOutputDevice)
    static var devicesAddr = globalAddr(kAudioHardwarePropertyDevices)

    /// 当前默认输入 / 输出设备（读不到返回 nil）
    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = input ? defaultInputAddr : defaultOutputAddr
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// 全部有对应方向声道的设备（保持系统返回顺序，轮换顺序可预期）
    static func devices(input: Bool) -> [AudioDeviceInfo] {
        var a = devicesAddr; var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        let scope: AudioObjectPropertyScope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        return ids.compactMap { id in
            guard channels(id, scope: scope) > 0 else { return nil }
            return AudioDeviceInfo(id: id, uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "\(id)", name: name(id) ?? "未知设备")
        }
    }

    /// 设备在指定方向的声道数（0 = 不是这个方向的设备）
    static func channels(_ d: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, buf) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func name(_ d: AudioDeviceID) -> String? { stringProp(d, kAudioObjectPropertyName) }
    static func stringProp(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, buf) == noErr else { return nil }
        let s = buf.load(as: CFString.self) as String
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func setDefault(_ d: AudioDeviceID, input: Bool) -> Bool {
        var a = input ? defaultInputAddr : defaultOutputAddr
        var id = d
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    /// 轮换：当前设备的下一个；不在列表里就切到第一个；空列表不动（纯函数便于测试）
    static func next(_ list: [AudioDeviceInfo], current: AudioDeviceID?) -> AudioDeviceID? {
        guard let first = list.first else { return nil }
        guard let i = list.firstIndex(where: { $0.id == current }) else { return first.id }
        return list[(i + 1) % list.count].id
    }
}

// MARK: - 多热键中心（Carbon，按 EventHotKeyID 分发）
/// CommandPalette 与音频快捷键共用一个 Carbon 事件处理器，按 hotkey id 分发到各自动作。
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private(set) var status: [UInt32: OSStatus] = [:]

    private func ensureHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeyCenter.shared.actions[id.id]?()
            return noErr
        }, 1, &spec, nil, &handler)
    }

    @discardableResult
    func register(_ id: UInt32, code: UInt32, mods: UInt32, action: @escaping () -> Void) -> OSStatus {
        unregister(id)
        ensureHandler()
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(code, mods, EventHotKeyID(signature: OSType(0x4D4F5054), id: id), GetApplicationEventTarget(), 0, &ref)   // 'MOPT'
        status[id] = st
        if st == noErr { refs[id] = ref; actions[id] = action }
        return st
    }
    func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        actions.removeValue(forKey: id); status.removeValue(forKey: id)
    }
    func failed(_ id: UInt32) -> Bool { status[id].map { $0 != noErr } ?? false }
}

// MARK: - 快捷键配置与动作
/// 可录制的全局快捷键：命令面板（默认 ⌥Space）+ 麦克风静音 + 输出 / 输入设备轮换。
/// 新热键默认不设置，避免与其他应用冲突；存储键保持与命令面板相同的 `*.code` / `*.mods` 结构。
enum HotKeySlot: String, CaseIterable {
    case palette, micMute, outputNext, inputNext

    var hkID: UInt32 {
        switch self { case .palette: return 1; case .micMute: return 2; case .outputNext: return 3; case .inputNext: return 4 }
    }
    var storeBase: String {
        switch self { case .palette: return "hotkey"; default: return "hotkey.audio.\(rawValue)" }
    }
    var title: String {
        switch self {
        case .palette: return "全局命令面板"
        case .micMute: return "麦克风静音"
        case .outputNext: return "切换输出设备"
        case .inputNext: return "切换输入设备"
        }
    }
    var symbol: String {
        switch self {
        case .palette: return "command"
        case .micMute: return "mic.slash.fill"
        case .outputNext: return "speaker.wave.2.fill"
        case .inputNext: return "mic.fill"
        }
    }
    var slug: String {
        switch self {
        case .palette: return "palette"
        case .micMute: return "mic-mute"
        case .outputNext: return "output-next"
        case .inputNext: return "input-next"
        }
    }
    var sub: String {
        switch self {
        case .palette: return "在任何地方唤起搜索：接显示器、体检、关标签页"
        case .micMute: return "在任何地方按一下静音 / 取消静音当前输入设备"
        case .outputNext: return "按列表顺序轮换声音输出（内建扬声器、耳机、显示器…）"
        case .inputNext: return "按列表顺序轮换声音输入（内建麦克风、耳机、外接麦…）"
        }
    }
    /// 只有命令面板有默认键位；其余默认未设置
    var `default`: (code: UInt32, mods: UInt32)? { self == .palette ? (49, UInt32(optionKey)) : nil }

    func stored(in d: UserDefaults = .standard) -> (code: UInt32, mods: UInt32)? {
        guard d.object(forKey: storeBase + ".code") != nil else { return `default` }
        return (UInt32(d.integer(forKey: storeBase + ".code")), UInt32(d.integer(forKey: storeBase + ".mods")))
    }
    func save(code: UInt32, mods: UInt32, in d: UserDefaults = .standard) {
        d.set(Int(code), forKey: storeBase + ".code")
        d.set(Int(mods), forKey: storeBase + ".mods")
    }
    func clear(in d: UserDefaults = .standard) {
        d.removeObject(forKey: storeBase + ".code")
        d.removeObject(forKey: storeBase + ".mods")
    }
    func label(in d: UserDefaults = .standard) -> String {
        guard let s = stored(in: d) else { return "未设置" }
        return CommandPalette.label(code: s.code, mods: s.mods)
    }

    func run() {
        switch self {
        case .palette: CommandPalette.shared.toggle()
        case .micMute:
            let m = !Mic.muted
            if Mic.setMuted(m) { UIState.shared.micMuted = m; SplitHUD.show(m ? "麦克风已静音" : "麦克风已取消静音") }
        case .outputNext:
            if let n = TrioModel.shared.cycleOutput(), let d = TrioModel.shared.outputs.first(where: { $0.id == n }) { SplitHUD.show("已切换输出到 \(d.name)") }
        case .inputNext:
            if let n = TrioModel.shared.cycleInput(), let d = TrioModel.shared.inputs.first(where: { $0.id == n }) { SplitHUD.show("已切换输入到 \(d.name)") }
        }
    }

    func install(in d: UserDefaults = .standard) {
        if let s = stored(in: d) {
            _ = HotKeyCenter.shared.register(hkID, code: s.code, mods: s.mods) { self.run() }
        } else {
            HotKeyCenter.shared.unregister(hkID)
        }
    }
    static func installAll() { allCases.forEach { $0.install() } }
}
