// 蓝牙设备电量：已配对设备列表（system_profiler，0.1 秒）+ 三个只读来源合并：
// 1) IORegistry BatteryPercent（Apple 妙控等） 2) system_profiler 的 AirPods 电量 3) CoreBluetooth 标准电量服务 0x180F（Logitech MX 等 BLE 设备）
// 每 5 分钟刷新一次（容差 1 分钟），打开页面/面板时立即刷新；不做持续扫描，不连接未连接的设备
import Foundation
import CoreBluetooth
import UserNotifications
import IOBluetooth

struct BTDevice: Identifiable, Equatable, Codable {
    var id: String { address.isEmpty ? name : address }
    var name: String
    var address: String
    var kind: String            // SF Symbol
    var connected: Bool
    var ble: Bool
    var percent: Int?
    var parts: [String: Int] = [:]   // AirPods：左/右/盒
    var source = ""                  // 读取方式
    var reason = ""                  // 读不到时的原因
}

enum BTKind {
    static func symbol(_ name: String, minor: String) -> String {
        let l = (name + " " + minor).lowercased()
        if l.contains("airpods") { return "airpodspro" }
        if l.contains("headphone") || l.contains("headset") || l.contains("soundcore") || l.contains("耳机") { return "headphones" }
        if l.contains("mouse") || l.contains("trackpad") || l.contains("鼠标") { return "computermouse" }
        if l.contains("keyboard") || l.contains("keys") || l.contains("键盘") { return "keyboard" }
        if l.contains("遥控") || l.contains("remote") { return "appletvremote.gen4" }
        if l.contains("iphone") { return "iphone" }
        if l.contains("ipad") { return "ipad" }
        return "dot.radiowaves.left.and.right"
    }
}

/// 数据来源抽象（测试用模拟）
protocol BTSource: AnyObject {
    func paired() -> [BTDevice]                       // system_profiler（含 AirPods 电量）
    func classic() -> [String: Int]
    func keychron() -> [KeychronReading]
    func keychronAccess() -> KeychronHID.Access
    func ioreg() -> [String: Int]                     // 名称 → 电量
    func gatt(_ done: @escaping ([String: Int], String?) -> Void)   // CoreBluetooth：名称 → 电量；第二个值 = 不可用原因
}

extension BTSource {
    func classic() -> [String: Int] { [:] }
    // 2.10：Keychron 键盘自报电量；默认不读（测试用模拟源覆盖）
    func keychron() -> [KeychronReading] { [] }
    func keychronAccess() -> KeychronHID.Access { .notAsked }
}

enum BTParse {
    static func address(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "-", with: ":") }
    static func profiler(_ json: Data) -> [BTDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]], let d = arr.first else { return [] }
        var out: [BTDevice] = []
        for (grp, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for e in d[grp] as? [[String: Any]] ?? [] {
                for (name, v) in e {
                    guard let p = v as? [String: Any] else { continue }
                    let minor = p["device_minorType"] as? String ?? ""
                    if minor.isEmpty && name.lowercased().contains("iphone") { continue }   // 手机不算外设
                    var dev = BTDevice(name: name, address: p["device_address"] as? String ?? "", kind: BTKind.symbol(name, minor: minor), connected: connected,
                                       ble: (p["device_services"] as? String ?? "").contains("BLE"))
                    func pct(_ k: String) -> Int? { (p[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) } }
                    for (k, label) in [("device_batteryLevelLeft", "左"), ("device_batteryLevelRight", "右"), ("device_batteryLevelCase", "盒")] { if let v = pct(k), (0...100).contains(v) { dev.parts[label] = v } }
                    if let m = pct("device_batteryLevelMain") ?? pct("device_batteryLevel"), (0...100).contains(m) { dev.percent = m }
                    else if !dev.parts.isEmpty { dev.percent = [dev.parts["左"], dev.parts["右"]].compactMap { $0 }.min() ?? dev.parts.values.min() }
                    if dev.percent != nil { dev.source = "系统蓝牙信息" }
                    out.append(dev)
                }
            }
        }
        return out
    }
    /// 合并三方数据，并给读不到的设备写明原因
    static func merge(paired: [BTDevice], ioreg: [String: Int], gatt: [String: Int], gattIssue: String?, classic: [String: Int] = [:]) -> [BTDevice] {
        var list = paired
        for i in list.indices {
            guard list[i].connected else { list[i].percent = nil; list[i].reason = "未连接"; continue }
            guard list[i].percent == nil else { continue }
            if let value = classic[address(list[i].address)], (1...100).contains(value) { list[i].percent = value; list[i].source = "系统经典蓝牙读数"; continue }
            let uniqueName = list.filter { $0.name == list[i].name && $0.connected }.count == 1
            if uniqueName, let v = ioreg[list[i].name], (0...100).contains(v) { list[i].percent = v; list[i].source = "系统电量（IORegistry）"; continue }
            if uniqueName, let v = gatt[list[i].name], (0...100).contains(v) { list[i].percent = v; list[i].source = "蓝牙标准电量服务"; continue }
            if let g = gattIssue, list[i].ble { list[i].reason = g; continue }
            list[i].reason = list[i].ble ? "未取得标准电量服务读数" : "未取得经典蓝牙电量，可能与型号或固件有关"
        }
        // IORegistry 里有但不在配对列表的（如 USB 接收器连接的设备）
        for (n, v) in ioreg where (0...100).contains(v) && !list.contains(where: { $0.name == n }) {
            list.append(BTDevice(name: n, address: "", kind: BTKind.symbol(n, minor: ""), connected: true, ble: false, percent: v, source: "系统电量（IORegistry）"))
        }
        return list.sorted { ($0.connected ? 0 : 1, $0.percent == nil ? 1 : 0, $0.name) < ($1.connected ? 0 : 1, $1.percent == nil ? 1 : 0, $1.name) }
    }
}

final class RealBTSource: NSObject, BTSource, CBCentralManagerDelegate, CBPeripheralDelegate {
    func paired() -> [BTDevice] { BTParse.profiler(Data(RealRunner().run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"]).out.utf8)) }
    func ioreg() -> [String: Int] { Dictionary(Readers.devices().map { ($0.name, $0.percent) }, uniquingKeysWith: { a, _ in a }) }
    func classic() -> [String: Int] {
        guard CBManager.authorization != .denied && CBManager.authorization != .restricted else { return [:] }
        guard CBManager.authorization != .notDetermined || BTBattery.shared.userAsked else { return [:] }
        guard let executable = Bundle.main.executableURL else { return [:] }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = ["--read-classic-batteries"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }; process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }
    func keychron() -> [KeychronReading] { KeychronHID.read() }
    func keychronAccess() -> KeychronHID.Access { KeychronHID.access() }
    static func printClassicSnapshot() {
        var values: [String: Int] = [:]
        let selector = "batteryPercentSingle"
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] {
            guard device.isConnected(), device.responds(to: NSSelectorFromString(selector)),
                  let value = device.value(forKey: selector) as? NSNumber, (1...100).contains(value.intValue),
                  let address = device.addressString else { continue }
            values[BTParse.address(address)] = value.intValue
        }
        if let data = try? JSONEncoder().encode(values) { FileHandle.standardOutput.write(data) }
    }
    private var cm: CBCentralManager?
    private var peers: [CBPeripheral] = []
    private var got: [String: Int] = [:]
    private var waiting: [([String: Int], String?) -> Void] = []
    private var finish: DispatchWorkItem?
    static let battery = CBUUID(string: "180F"), level = CBUUID(string: "2A19")
    func gatt(_ done: @escaping ([String: Int], String?) -> Void) {
        DispatchQueue.main.async {
            switch CBManager.authorization {
            case .denied, .restricted: done([:], "没有蓝牙权限（系统设置 › 隐私与安全性 › 蓝牙）"); return
            case .notDetermined where !BTBattery.shared.userAsked: done([:], "打开电池页后会请求蓝牙权限"); return
            default: break
            }
            self.waiting.append(done)
            guard self.waiting.count == 1 else { return }
            self.got = [:]
            if let cm = self.cm, cm.state == .poweredOn { self.query(cm) } else if self.cm == nil { self.cm = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
            let w = DispatchWorkItem { self.complete(nil) }; self.finish = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
        }
    }
    private func complete(_ issue: String?) {
        finish?.cancel(); finish = nil
        peers = []
        let cbs = waiting; waiting = []
        cm?.delegate = nil; cm = nil          // 不常驻蓝牙中心，省内存
        cbs.forEach { $0(got, issue) }
    }
    private func query(_ c: CBCentralManager) {
        peers = c.retrieveConnectedPeripherals(withServices: [Self.battery])
        if peers.isEmpty { complete(nil); return }
        for p in peers { p.delegate = self; c.connect(p) }
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: if !waiting.isEmpty { query(c) }
        case .unauthorized: complete("没有蓝牙权限（系统设置 › 隐私与安全性 › 蓝牙）")
        case .poweredOff: complete("蓝牙已关闭")
        case .unsupported: complete("这台 Mac 不支持低功耗蓝牙")
        default: break
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.battery]) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) { for s in p.services ?? [] where s.uuid == Self.battery { p.discoverCharacteristics([Self.level], for: s) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) { for ch in s.characteristics ?? [] where ch.uuid == Self.level { p.readValue(for: ch) } }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        if e == nil, ch.uuid == Self.level, let v = ch.value?.first, v <= 100, let n = p.name { got[n] = Int(v) }
        if got.count >= peers.count { complete(nil) }
    }
}

struct BTSettings: Codable, Equatable {
    var lowAlert = false        // 低电量通知：默认关闭
    var threshold = 20
    static let key = "bt.settings"
    static func load(_ d: UserDefaults = .standard) -> BTSettings { d.data(forKey: key).flatMap { try? JSONDecoder().decode(BTSettings.self, from: $0) } ?? BTSettings() }
    func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

final class BTBattery: ObservableObject {
    static var shared = BTBattery()
    @Published var devices: [BTDevice] = []
    @Published var updated: Date?
    @Published var loading = false
    @Published var settings = BTSettings.load() { didSet { if persist { settings.save() } } }
    var source: BTSource = RealBTSource()
    var persist = true
    var notify: (String, String) -> Void = { t, b in
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bt-\(t)", content: c, trigger: nil))
    }
    var userAsked = UserDefaults.standard.bool(forKey: "bt.asked") { didSet { if persist { UserDefaults.standard.set(userAsked, forKey: "bt.asked") } } }
    private var alerted: Set<String> = []
    private var timer: Timer?
    static let interval: TimeInterval = 300
    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }; t.tolerance = 60
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func stop() { timer?.invalidate(); timer = nil }
    var running: Bool { timer != nil }
    func refresh(done: (() -> Void)? = nil) {
        guard !loading else { done?(); return }
        loading = true
        let src = source
        DispatchQueue.global(qos: .utility).async {
            let paired = src.paired(), io = src.ioreg(), classic = src.classic()
            let needGatt = paired.contains { $0.connected && $0.ble && $0.percent == nil && io[$0.name] == nil }
            let finish: ([String: Int], String?) -> Void = { g, issue in
                var list = BTParse.merge(paired: paired, ioreg: io, gatt: g, gattIssue: issue, classic: classic)
                // 只有存在读不到电量的 Keychron 键盘、且用户已授权时才去读 HID
                if list.contains(where: KeychronHID.candidate) {
                    let access = src.keychronAccess()
                    list = BTParse.apply(hid: access == .granted ? src.keychron() : [], to: list, access: access)
                }
                DispatchQueue.main.async { self.devices = list; self.updated = Date(); self.loading = false; self.checkAlerts(); done?() }
            }
            if needGatt { src.gatt(finish) } else { finish([:], nil) }
        }
    }
    /// 低电量：每台设备跌破阈值时提醒一次，回升 10% 后才会再次提醒
    func checkAlerts() {
        for d in devices { guard d.connected, let p = d.percent else { continue }
            if p > settings.threshold + 10 { alerted.remove(d.id) }
            if settings.lowAlert, p <= settings.threshold, !alerted.contains(d.id) { alerted.insert(d.id); notify("\(d.name) 电量低", "剩余 \(p)%，记得充电") }
        }
    }
    var withBattery: [BTDevice] { devices.filter { $0.percent != nil } }
}
