// 2.10：Keychron 键盘自报电量（K02）
//
// Keychron K3 系列通过蓝牙 HID 的 3 号报告上报电量：8 字节，[0] = 报告号 3，[1] = 电量百分比，[2...7] = 键盘的蓝牙地址。
// macOS 不显示这个读数。读取键盘类 HID 设备需要「输入监控」权限，所以只在用户主动点了「读取」并授权后才做，
// 而且只取这一个报告，不监听任何按键。报告里的地址必须和已连接的配对设备对得上才采用，对不上一律不显示。
import Foundation
import AppKit
import IOKit
import IOKit.hid

struct KeychronReading: Equatable {
    let percent: Int
    let addresses: [String]      // 报告里的地址，正序和倒序两种写法（不同固件字节序不同）
}

enum KeychronHID {
    static let reportID = 3
    static let askedKey = "keychron.hidAsked"

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
            for (type, label) in [(kIOHIDReportTypeInput, "输入"), (kIOHIDReportTypeFeature, "特性")] {
                var buf = [UInt8](repeating: 0, count: 64); var len = buf.count
                let r = IOHIDDeviceGetReport(dev, type, CFIndex(reportID), &buf, &len)
                guard r == kIOReturnSuccess, len > 0 else { raw?("\(name)：\(label)报告 3 读取失败（\(String(format: "0x%08x", r))）"); continue }
                let bytes = Array(buf.prefix(len))
                raw?("\(name)：\(label)报告 3 = " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                if let reading = parse(bytes), !out.contains(reading) { out.append(reading); break }
            }
        }
        return out
    }
    static func printSnapshot() {
        var lines: [String] = []
        let readings = read { lines.append($0) }
        for l in lines { print(l) }
        for r in readings { print("解析结果：\(r.percent)%，地址 \(r.addresses[0])") }
        if readings.isEmpty { print("没有读到可用的电量") }
    }
}

extension BTParse {
    /// 把键盘自报的电量并进设备列表：只认地址对得上的已连接设备
    static func apply(hid: [KeychronReading], to list: [BTDevice], access: KeychronHID.Access) -> [BTDevice] {
        var out = list
        for i in out.indices where KeychronHID.candidate(out[i]) {
            let a = address(out[i].address)
            if let r = hid.first(where: { $0.addresses.contains(a) }) {
                out[i].percent = r.percent; out[i].source = "键盘自报电量（HID）"; out[i].reason = ""; out[i].reasonKind = nil
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
