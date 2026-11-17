// 2.10：Keychron 键盘自报电量（K02）
//
// Keychron K3 系列通过蓝牙 HID 的 3 号报告上报电量：8 字节，[0] = 报告号 3，[1] = 电量百分比，[2...7] = 键盘的蓝牙地址。
// macOS 不显示这个读数。读取键盘类 HID 设备需要「输入监控」权限，所以只在用户主动点了「读取」并授权后才做，
// 而且只取这一个报告，不监听任何按键。报告里的地址必须和已连接的配对设备对得上才采用，对不上一律不显示。
//
// K3 Pro（K3P-H3，CKBT51 模块）实测结论：报告 3 不在 HID 描述符里，是蓝牙模块私推的值，固件 1.3.2 下从不更新
// （实际约 70% 时报 100%；重连、充电、按 Fn+B、长时间放电都不变）。特性报告不支持（0xe00002c7），
// 无 BLE 广播，USB raw-HID 通道只有 VIA/工厂测试命令、没有电量查询。因此对自报值做陈旧检测：
// 同一个值超过可信窗口没变就判定固件不再推送，降级为「未取得」并提示按 Fn+B 查看，不再显示假值。
import Foundation
import AppKit
import IOKit
import IOKit.hid
import CoreBluetooth

/// BLE 诊断：扫 K3 Pro 的 BLE 广播并枚举 GATT 服务/特征（--ble-keychron）
final class KeychronBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = KeychronBLE()
    var central: CBCentralManager!
    var target: CBPeripheral?
    let found = NSMutableArray()
    let t0 = Date()
    func t() -> String { String(format: "t+%03ds", Int(Date().timeIntervalSince(t0))) }
    func run(_ seconds: Double) {
        central = CBCentralManager(delegate: self, queue: nil)
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        print("扫描结束")
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("\(t()) 蓝牙状态 \(c.state.rawValue)")
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: nil, options: nil)
        print("\(t()) 开始扫描…")
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().contains("keychron") else { return }
        if found.contains(p) { return }
        found.add(p)
        let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        print("\(t()) 发现：\(name) \(p.identifier) rssi=\(rssi) 广播服务=\(svcs.map { $0.uuidString })")
        target = p
        c.stopScan()
        c.connect(p, options: nil)
        print("\(t()) 连接中…")
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("\(t()) 已连接，枚举服务…")
        p.delegate = self
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("\(t()) 连接失败：\(error?.localizedDescription ?? "?")")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            print("\(t()) 服务 \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("\(t())   特征 \(ch.uuid) props=\(ch.properties.rawValue)")
            if ch.properties.contains(.read) { p.readValue(for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let v = ch.value {
            print("\(t())   特征 \(ch.uuid) = " + v.map { String(format: "%02x", $0) }.joined(separator: " ") + (ch.uuid == CBUUID(string: "2A19") ? "（电量 \(v.first ?? 0)%）" : ""))
        }
    }
}

struct KeychronReading: Equatable {
    let percent: Int
    let addresses: [String]      // 报告里的地址，正序和倒序两种写法（不同固件字节序不同）
    var stale = false            // 自报值长期未变：固件可能根本不更新此值（K3 Pro 实测如此），不再当电量显示
}

enum KeychronHID {
    static let reportID = 3
    static let askedKey = "keychron.hidAsked"
    /// 自报值可信窗口：从未观察到更新的通道给短引信（K3 Pro 实测固件不刷新，值是死的）；
    /// 曾经推送过新值的通道证明是活的，给长引信（真实电量也可能几天不变）。
    static let staleAfterUntested: TimeInterval = 86400
    static let staleAfterProven: TimeInterval = 7 * 86400

    /// 自报值陈旧检测：按报告里的地址记住「当前电量值最早什么时候看到的」以及「是否曾经更新过」。
    /// 值一变就重置计时并标记通道是活的；超过对应窗口没变 → stale=true，降级为「未取得」。
    static func markFreshness(_ rs: [KeychronReading], defaults: UserDefaults = .standard, now: Date = Date()) -> [KeychronReading] {
        rs.map { r in
            var r = r
            guard let addr = r.addresses.first else { return r }
            let key = "keychron.seen.\(addr)"
            let d = defaults.dictionary(forKey: key)
            var since = now, changed = false
            if let p = d?["p"] as? Int, let t = d?["t"] as? TimeInterval, p == r.percent {
                since = Date(timeIntervalSince1970: t)
                changed = (d?["c"] as? Int) == 1
            } else {
                changed = d?["p"] != nil        // 换值了 → 这个通道确实会推送
                defaults.set(["p": r.percent, "t": now.timeIntervalSince1970, "c": changed ? 1 : 0], forKey: key)
            }
            r.stale = now.timeIntervalSince(since) > (changed ? staleAfterProven : staleAfterUntested)
            return r
        }
    }

    /// 解析 3 号报告；格式不对返回 nil
    static func parse(_ b: [UInt8]) -> KeychronReading? {
        guard b.count >= 8, b[0] == UInt8(reportID), (1...100).contains(Int(b[1])) else { return nil }
        let addr = Array(b[2..<8])
        guard addr.contains(where: { $0 != 0 }), addr.contains(where: { $0 != 0xFF }) else { return nil }
        func text(_ a: [UInt8]) -> String { a.map { String(format: "%02x", $0) }.joined(separator: ":") }
        return KeychronReading(percent: Int(b[1]), addresses: [text(addr), text(addr.reversed())])
    }
    /// 哪些设备值得去读：已连接、还没有电量、名字是 Keychron
    static func candidate(_ d: BTDevice) -> Bool { d.connected && d.percent == nil && d.name.lowercased().contains("keychron") }

    enum Access { case granted, denied, notAsked }
    static func access() -> Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notAsked
        }
    }
    /// 弹出系统的「输入监控」授权；返回是否已授权
    @discardableResult static func request() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(u) }
    }

    /// 读取所有蓝牙连接的 Keychron 键盘；raw 用于排查（--read-keychron-battery）
    static func read(raw: ((String) -> Void)? = nil) -> [KeychronReading] {
        guard access() == .granted else { raw?("没有「输入监控」权限"); return [] }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDTransportKey: "Bluetooth"] as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { raw?("打不开 HID 管理器"); return [] }
        defer { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        var out: [KeychronReading] = []
        for dev in (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? [] {
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? ""
            guard name.lowercased().contains("keychron") else { continue }
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { raw?("\(name)：打不开设备"); continue }
            defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
            // 2.17：先读特性报告——get_report 是主动向设备请求的活数据；
            // 输入报告返回的是驱动缓存的最后一次上报，键盘不主动推时会一直停在旧值（此前放电后仍显示 100%）
            var parsed: KeychronReading?
            for (type, label) in [(kIOHIDReportTypeFeature, "特性"), (kIOHIDReportTypeInput, "输入")] {
                var buf = [UInt8](repeating: 0, count: 64); var len = buf.count
                let r = IOHIDDeviceGetReport(dev, type, CFIndex(reportID), &buf, &len)
                guard r == kIOReturnSuccess, len > 0 else { raw?("\(name)：\(label)报告 3 读取失败（\(String(format: "0x%08x", r))）"); continue }
                let bytes = Array(buf.prefix(len))
                raw?("\(name)：\(label)报告 3 = " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                if parsed == nil { parsed = parse(bytes) }
            }
            if let p = parsed, !out.contains(p) { out.append(p) }
        }
        return markFreshness(out)
    }
    static func printSnapshot() {
        var lines: [String] = []
        let readings = read { lines.append($0) }
        for l in lines { print(l) }
        for r in readings { print("解析结果：\(r.percent)%，地址 \(r.addresses[0])\(r.stale ? "（自报值长期未变，不采用）" : "")") }
        if readings.isEmpty { print("没有读到可用的电量") }
    }

    /// 排查用：打印每个 Keychron HID 节点的用法页、报告描述符和 1–8 号输入报告
    static func dumpHID() {
        guard access() == .granted else { print("没有「输入监控」权限"); return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, nil)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("打不开 HID 管理器"); return }
        defer { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        for dev in (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? [] {
            let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? ""
            let up0 = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let u0 = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let vid0 = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let tr0 = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String ?? "?"
            print("  设备：\(name) vid \(String(format: "0x%04x", vid0)) page \(String(format: "0x%02x", up0)) usage \(String(format: "0x%02x", u0)) 传输 \(tr0)")
            guard name.lowercased().contains("keychron") || vid0 == 0x3434 else { continue }
            let up = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let u = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let vid = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
            print("\(name)：usagePage \(String(format: "0x%02x", up)) usage \(String(format: "0x%02x", u)) vid:pid \(String(format: "0x%04x:0x%04x", vid, pid))")
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("  打不开设备"); continue }
            defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
            if let d = IOHIDDeviceGetProperty(dev, kIOHIDReportDescriptorKey as CFString) as? Data {
                print("  描述符 \(d.count) 字节：" + d.map { String(format: "%02x", $0) }.joined(separator: " "))
            }
            for id in 1...255 {
                var buf = [UInt8](repeating: 0, count: 64); var len = buf.count
                let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, CFIndex(id), &buf, &len)
                if r == kIOReturnSuccess, len > 0 {
                    print("  输入报告 \(id) = " + Array(buf.prefix(len)).map { String(format: "%02x", $0) }.joined(separator: " "))
                }
            }
            for id in 1...255 {
                var buf = [UInt8](repeating: 0, count: 64); var len = buf.count
                let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len)
                if r == kIOReturnSuccess, len > 0 {
                    print("  特性报告 \(id) = " + Array(buf.prefix(len)).map { String(format: "%02x", $0) }.joined(separator: " "))
                }
            }
        }
    }

    /// 排查用：轮询缓存的报告 3/5，变化时打时间戳（同时写入 logPath 便于长时间挂后台）。
    /// 推送回调对 BT 键盘无效（系统独占设备），只能轮询驱动缓存——值一变就说明键盘推了新报。
    static func watch(seconds: Int = 1800, interval: TimeInterval = 5, logPath: String? = nil) {
        guard access() == .granted else { print("没有「输入监控」权限"); return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDTransportKey: "Bluetooth"] as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("打不开 HID 管理器"); return }
        defer { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let dev = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first(where: {
            (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "").lowercased().contains("keychron")
        }) else { print("没找到 Keychron 设备"); return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("打不开设备"); return }
        defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        func log(_ s: String) {
            let line = "\(fmt.string(from: Date())) \(s)"
            print(line)
            if let p = logPath, let d = (line + "\n").data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: p)) { h.seekToEndOfFile(); h.write(d); try? h.close() }
                else { try? d.write(to: URL(fileURLWithPath: p)) }
            }
        }
        log("开始监听 \(seconds) 秒，每 \(Int(interval))s 轮询报告 3/5…")
        var last: [Int: [UInt8]] = [:]
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            for id in [3, 5] {
                var buf = [UInt8](repeating: 0, count: 64); var len = buf.count
                let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, CFIndex(id), &buf, &len)
                guard r == kIOReturnSuccess, len > 0 else { continue }
                let bytes = Array(buf.prefix(len))
                if bytes != last[id] {
                    last[id] = bytes
                    log("报告 \(id) = " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                }
            }
            Thread.sleep(forTimeInterval: interval)
        }
        log("监听结束")
    }

    /// BLE 通道诊断（--ble-keychron）
    static func bleScan(seconds: Double = 30) { KeychronBLE.shared.run(seconds) }

    /// 排查用：向 USB raw-HID 接口（usagePage 0xFF60）发命令并打印回应（--probe-keychron-raw）
    static func probeRaw() {
        guard access() == .granted else { print("没有「输入监控」权限"); return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x3434, kIOHIDPrimaryUsagePageKey: 0xFF60] as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("打不开 HID 管理器"); return }
        defer { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let dev = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first else {
            print("没有 raw-HID 接口（键盘要插线才会枚举）"); return }
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? ""
        print("找到 raw-HID 接口：\(name)")
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("打不开设备"); return }
        defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
        // 回调收回应
        final class Ctx { var got = false }
        let ctx = Ctx()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let cctx = Unmanaged.passRetained(ctx).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { cc, _, _, _, _, rpt, len in
            let c = Unmanaged<Ctx>.fromOpaque(cc!).takeUnretainedValue()
            c.got = true
            print("  回应 = " + Array(UnsafeBufferPointer(start: rpt, count: len)).map { String(format: "%02x", $0) }.joined(separator: " "))
        }, cctx)
        func send(_ bytes: [UInt8], _ label: String) {
            var out = [UInt8](repeating: 0, count: 32)
            for (i, b) in bytes.enumerated() where i < 32 { out[i] = b }
            let r = out.withUnsafeMutableBytes { IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), 32) }
            print("发送 \(label)（\(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))）：\(r == kIOReturnSuccess ? "已发" : String(format: "失败 0x%08x", r))")
            ctx.got = false
            CFRunLoopRunInMode(.defaultMode, 1.0, false)
            if !ctx.got { print("  （无回应）") }
        }
        send([0x01], "VIA 协议版本")
        send([0xAB, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00], "工厂测试 GET_TRANSPORT")
        send([0xA4], "KC_GET_BATTERY 0xA4")
        send([0xAB, 0x06, 0xA2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA8, 0x00], "工厂测试 CHARGING_ADC")
        Unmanaged<Ctx>.fromOpaque(cctx).release()
    }
}

extension BTParse {
    /// 把键盘自报的电量并进设备列表：只认地址对得上的已连接设备
    static func apply(hid: [KeychronReading], to list: [BTDevice], access: KeychronHID.Access) -> [BTDevice] {
        var out = list
        for i in out.indices where KeychronHID.candidate(out[i]) {
            let a = address(out[i].address)
            if let r = hid.first(where: { $0.addresses.contains(a) }) {
                if r.stale {
                    out[i].reason = "键盘自报的电量长时间没有变化，该固件可能不刷新这个值；按键盘 Fn+B 可查看实际电量"
                    out[i].reasonKind = .noReport
                } else {
                    out[i].percent = r.percent; out[i].source = "键盘自报电量（HID）"; out[i].reason = ""; out[i].reasonKind = nil
                }
            } else {
                switch access {
                case .granted: out[i].reason = "已有输入监控权限，但键盘没有返回可核对的电量"; out[i].reasonKind = .noReport
                case .denied: out[i].reason = "需要在系统设置里允许「输入监控」，才能读取键盘自报的电量"; out[i].reasonKind = .unauthorized
                case .notAsked: out[i].reason = "点「读取 Keychron 电量」并允许「输入监控」后可读取"; out[i].reasonKind = .unauthorized
                }
            }
        }
        return out.sorted { ($0.connected ? 0 : 1, $0.percent == nil ? 1 : 0, $0.name) < ($1.connected ? 0 : 1, $1.percent == nil ? 1 : 0, $1.name) }
    }
}
