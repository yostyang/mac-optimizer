import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import SystemConfiguration
import CoreAudio
import AppKit
import Darwin

// MARK: - 数据
struct ProcInfo: Identifiable, Equatable { let id: Int32; let name: String; let cpu: Double; let memMB: Double }
struct DeviceBattery: Identifiable, Equatable { var id: String { name }; let name: String; let percent: Int; let kind: String }

struct Snapshot: Equatable {
    // 静态
    var chip = ""; var ramGB = 0; var osVersion = ""; var pCores = 0; var eCores = 0; var gpuCores = 0
    // 动态
    var uptime: TimeInterval = 0
    var cpu: Double = 0; var load: [Double] = [0, 0, 0]; var cpuTemp: Double? = nil
    var gpu: Double? = nil; var gpuTemp: Double? = nil
    var memUsedGB = 0.0; var memTotalGB = 0.0; var memPressure = 1; var swapUsedGB = 0.0
    var diskTotalGB = 0.0; var diskFreeGB = 0.0
    var netIface = ""; var netKind = ""; var upBps = 0.0; var downBps = 0.0; var proxy = ""
    var fans: [Double]? = nil; var fanMin = 0.0; var fanMax = 0.0
    var battery: Int? = nil; var batteryHealth: Int? = nil; var charging = false; var onAC = false; var cycles: Int? = nil; var timeRemaining: Int? = nil
    var devices: [DeviceBattery] = []
    var batteryTemp: Double? = nil; var batteryCondition = ""; var designMah = 0; var fullMah = 0
    var top: [ProcInfo] = []
    var memFraction: Double { memTotalGB > 0 ? memUsedGB / memTotalGB : 0 }
    var diskUsedFraction: Double { diskTotalGB > 0 ? 1 - diskFreeGB / diskTotalGB : 0 }

    /// 健康分 + 一句话状态
    var health: (score: Int, status: String) {
        var pen = 0; var why: [(Int, String)] = []
        func add(_ p: Int, _ s: String) { pen += p; why.append((p, s)) }
        if cpu > 85 { add(15, "CPU 占用很高") } else if cpu > 60 { add(6, "CPU 有点忙") }
        if memPressure >= 4 { add(25, "内存非常紧张") } else if memPressure >= 2 { add(12, "内存压力偏高") }
        if swapUsedGB > 4 { add(6, "交换内存用得较多") }
        if let t = cpuTemp { if t > 90 { add(15, "CPU 温度过高") } else if t > 78 { add(5, "CPU 温度偏高") } }
        if diskTotalGB > 0 { let f = diskFreeGB / diskTotalGB; if f < 0.08 { add(15, "磁盘快满了") } else if f < 0.15 { add(5, "磁盘空间偏少") } }
        if uptime > 14 * 86400 { add(5, "很久没重启了") }
        let top = why.max { $0.0 < $1.0 }?.1
        return (max(0, 100 - pen), top ?? "一切正常")
    }
}

// MARK: - 读取器（全部使用无需权限的系统接口，不调用命令行）
enum Readers {
    static func sysctlString(_ n: String) -> String {
        var size = 0; guard sysctlbyname(n, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var b = [CChar](repeating: 0, count: size); sysctlbyname(n, &b, &size, nil, 0); return String(cString: b)
    }
    static func sysctlInt(_ n: String) -> Int? {
        var v: Int64 = 0; var size = MemoryLayout<Int64>.size
        guard sysctlbyname(n, &v, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
    }
    static func staticInfo(into s: inout Snapshot) {
        s.chip = sysctlString("machdep.cpu.brand_string").replacingOccurrences(of: "Apple ", with: "")
        s.ramGB = Int((sysctlInt("hw.memsize") ?? 0) / 1_073_741_824)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        s.osVersion = "macOS \(v.majorVersion)" + (v.minorVersion > 0 ? ".\(v.minorVersion)" : "")
        s.pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? (sysctlInt("hw.physicalcpu") ?? 0)
        s.eCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        s.gpuCores = gpuInfo().cores ?? 0
    }
    static func uptime() -> TimeInterval {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    // CPU：host_processor_info 差值
    private static var prevTicks: [UInt32] = []
    static func cpuUsage() -> Double {
        var count: mach_msg_type_number_t = 0; var info: processor_info_array_t?; var n: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(n) {
            let b = c * Int(CPU_STATE_MAX)
            var d = [UInt64](repeating: 0, count: Int(CPU_STATE_MAX))
            for k in 0..<Int(CPU_STATE_MAX) { d[k] = UInt64(ticks[b + k] &- prevTicks[b + k]) }
            busy += d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            total += d.reduce(0, +)
        }
        return total > 0 ? min(100, Double(busy) / Double(total) * 100) : 0
    }
    static func loadAvg() -> [Double] { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l }

    // 内存
    static func memory(into s: inout Snapshot) {
        var st = vm_statistics64(); var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &st) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) } }
        let page = Double(vm_kernel_page_size)
        let total = Double(sysctlInt("hw.memsize") ?? 0)
        s.memTotalGB = total / 1_073_741_824
        if r == KERN_SUCCESS {
            let app = Double(st.internal_page_count) - Double(st.purgeable_count)
            s.memUsedGB = (app + Double(st.wire_count) + Double(st.compressor_page_count)) * page / 1_073_741_824
        }
        s.memPressure = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        var sw = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 { s.swapUsedGB = Double(sw.xsu_used) / 1_073_741_824 }
    }

    // 磁盘
    static func disk(into s: inout Snapshot) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        s.diskTotalGB = Double(v?.volumeTotalCapacity ?? 0) / 1e9
        s.diskFreeGB = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
    }

    // 网络
    private static var prevNet: (UInt64, UInt64, Date, String)?
    private static var ifaceNames: [String: String] = [:]
    static func network(into s: inout Snapshot) {
        let store = SCDynamicStoreCreate(nil, "MacOptimizer" as CFString, nil, nil)
        let g = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) } as? [String: Any]
        let primary = g?["PrimaryInterface"] as? String ?? ""
        s.netIface = primary
        if ifaceNames.isEmpty, let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all { if let b = SCNetworkInterfaceGetBSDName(i) as String?, let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? { ifaceNames[b] = n } }
        }
        s.netKind = primary.isEmpty ? "未连接" : (primary.hasPrefix("utun") ? "VPN 隧道" : (ifaceNames[primary] ?? primary))
        if let px = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            func on(_ k: String) -> Bool { (px[k] as? Int ?? 0) == 1 }
            var m: [String] = []
            if on("SOCKSEnable") { m.append("SOCKS") }
            if on("HTTPEnable") || on("HTTPSEnable") { m.append("HTTP") }
            if on("ProxyAutoConfigEnable") { m.append("PAC") }
            s.proxy = m.isEmpty ? (primary.hasPrefix("utun") ? "VPN" : "直连") : m.joined(separator: "+")
        }
        var ib: UInt64 = 0, ob: UInt64 = 0
        var ifa: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifa) == 0 {
            var p = ifa
            while let c = p {
                let n = String(cString: c.pointee.ifa_name)
                if c.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), n == primary, let d = c.pointee.ifa_data {
                    let data = d.assumingMemoryBound(to: if_data.self).pointee
                    ib += UInt64(data.ifi_ibytes); ob += UInt64(data.ifi_obytes)
                }
                p = c.pointee.ifa_next
            }
            freeifaddrs(ifa)
        }
        let now = Date()
        if let (pi, po, pt, pn) = prevNet, pn == primary {
            let dt = max(0.2, now.timeIntervalSince(pt))
            func delta(_ a: UInt64, _ b: UInt64) -> Double { Double(a >= b ? a - b : a + (1 << 32) - b) }
            s.downBps = delta(ib, pi) / dt; s.upBps = delta(ob, po) / dt
        }
        prevNet = (ib, ob, now, primary)
    }

    // GPU：IOAccelerator 的 PerformanceStatistics
    static func gpuInfo() -> (util: Double?, cores: Int?) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(it) }
        var util: Double?, cores: Int?
        var o = IOIteratorNext(it)
        while o != 0 {
            if let st = IORegistryEntryCreateCFProperty(o, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any],
               let u = st["Device Utilization %"] as? NSNumber { util = u.doubleValue }
            if let c = IORegistryEntryCreateCFProperty(o, "gpu-core-count" as CFString, nil, 0)?.takeRetainedValue() as? NSNumber { cores = c.intValue }
            IOObjectRelease(o); o = IOIteratorNext(it)
        }
        return (util, cores)
    }

    // 电池
    static func battery(into s: inout Snapshot) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { s.battery = nil; return }
        defer { IOObjectRelease(svc) }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(svc, k as CFString, nil, 0)?.takeRetainedValue() }
        s.battery = (prop("CurrentCapacity") as? NSNumber)?.intValue
        s.charging = (prop("IsCharging") as? NSNumber)?.boolValue ?? false
        s.onAC = (prop("ExternalConnected") as? NSNumber)?.boolValue ?? false
        s.cycles = (prop("CycleCount") as? NSNumber)?.intValue
        let bd = prop("BatteryData") as? [String: Any]
        let design = (prop("DesignCapacity") as? NSNumber)?.doubleValue ?? (bd?["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
        let full = (prop("AppleRawMaxCapacity") as? NSNumber)?.doubleValue ?? (prop("NominalChargeCapacity") as? NSNumber)?.doubleValue ?? (bd?["NominalChargeCapacity"] as? NSNumber)?.doubleValue ?? 0
        s.designMah = Int(design); s.fullMah = Int(full)
        s.batteryTemp = (prop("Temperature") as? NSNumber).map { $0.doubleValue / 100 } ?? HIDTemp.batteryTemp()
        s.batteryCondition = "正常"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list { if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any], let h = d[kIOPSBatteryHealthKey] as? String {
                s.batteryCondition = h == "Good" ? "正常" : (h == "Fair" ? "一般" : (h == "Poor" ? "建议维修" : h)) } }
        }
        s.batteryHealth = design > 0 && full > 0 ? min(100, Int((full / design * 100).rounded())) : nil
        let t = (prop("TimeRemaining") as? NSNumber)?.intValue ?? 65535
        s.timeRemaining = t > 0 && t < 6000 ? t : nil
    }

    // 外接设备电量：系统已通过 IOKit 公开 BatteryPercent 的设备（苹果配件、部分 HID 设备）
    static func devices() -> [DeviceBattery] {
        var out: [DeviceBattery] = []
        for cls in ["AppleDeviceManagementHIDEventService", "IOHIDDevice", "AppleHSBluetoothDevice"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            var o = IOIteratorNext(it)
            while o != 0 {
                if let b = IORegistryEntryCreateCFProperty(o, "BatteryPercent" as CFString, nil, 0)?.takeRetainedValue() as? NSNumber {
                    let name = IORegistryEntryCreateCFProperty(o, "Product" as CFString, nil, 0)?.takeRetainedValue() as? String ?? "设备"
                    let l = name.lowercased()
                    let kind = l.contains("mouse") || l.contains("mx master") || l.contains("trackpad") ? "computermouse" : (l.contains("keyboard") || l.contains("key") ? "keyboard" : (l.contains("airpods") ? "airpodspro" : "dot.radiowaves.left.and.right"))
                    if !out.contains(where: { $0.name == name }) { out.append(DeviceBattery(name: name, percent: b.intValue, kind: kind)) }
                }
                IOObjectRelease(o); o = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        return out
    }

    // 进程：proc_pidinfo 差值（只能读到当前用户的进程，系统进程无权限读取会被跳过）
    private static var prevProc: [Int32: UInt64] = [:]
    private static var prevProcTime: UInt64 = 0
    private static var procNames: [Int32: String] = [:]
    private static let timebase: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()
    static func topProcesses(limit: Int = 5) -> [ProcInfo] {
        let n = proc_listallpids(nil, 0); guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let now = mach_absolute_time()
        let dtNs = prevProcTime > 0 ? Double(now - prevProcTime) * timebase : 0
        var cur: [Int32: UInt64] = [:]; var list: [ProcInfo] = []
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            var ti = proc_taskinfo()
            let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
            guard r == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            let t = ti.pti_total_user + ti.pti_total_system
            cur[pid] = t
            guard dtNs > 0, let p = prevProc[pid], t >= p else { continue }
            let cpu = Double(t - p) * timebase / dtNs * 100
            list.append(ProcInfo(id: pid, name: "", cpu: cpu, memMB: Double(ti.pti_resident_size) / 1_048_576))
        }
        // 只为前几名解析名称（并缓存），避免每次给几百个进程查名字
        list = Array(list.sorted { $0.cpu > $1.cpu }.prefix(limit)).map { p in
            if let n = procNames[p.id] { return ProcInfo(id: p.id, name: n, cpu: p.cpu, memMB: p.memMB) }
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(p.id, &nameBuf, 256)
            var name = String(cString: nameBuf)
            if let app = NSRunningApplication(processIdentifier: p.id), let ln = app.localizedName { name = ln }
            if name.isEmpty { name = "pid \(p.id)" }
            procNames[p.id] = name
            return ProcInfo(id: p.id, name: name, cpu: p.cpu, memMB: p.memMB)
        }
        if procNames.count > 200 { procNames = procNames.filter { cur[$0.key] != nil } }
        prevProc = cur; prevProcTime = now
        return list
    }

    // 自身资源占用
    static func selfUsage() -> (cpuSeconds: Double, rssMB: Double) {
        var ti = proc_taskinfo()
        _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return (Double(ti.pti_total_user + ti.pti_total_system) * timebase / 1e9, Double(ti.pti_resident_size) / 1_048_576)
    }
}

// MARK: - SMC（只读：温度和风扇转速；不需要管理员权限）
final class SMC {
    struct KI { var size: UInt32 = 0; var type: UInt32 = 0; var attr: UInt8 = 0; var p1: UInt8 = 0; var p2: UInt8 = 0; var p3: UInt8 = 0 }
    struct KeyData {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var plimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var info = KI(); var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0; var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    static let shared = SMC()
    private var conn: io_connect_t = 0
    private(set) var cpuKeys: [String] = []; private(set) var gpuKeys: [String] = []
    private var enumerated = false
    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if svc != 0 { _ = IOServiceOpen(svc, mach_task_self_, 0, &conn); IOObjectRelease(svc) }
    }
    var available: Bool { conn != 0 }
    static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func str(_ v: UInt32) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "" }
    private func call(_ i: inout KeyData) -> Bool {
        var o = KeyData(); var sz = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<KeyData>.stride, &o, &sz)
        i = o; return r == KERN_SUCCESS && o.result == 0
    }
    func read(_ k: String) -> (type: String, bytes: [UInt8])? {
        guard conn != 0 else { return nil }
        var i = KeyData(); i.key = SMC.fourcc(k); i.data8 = 9
        guard call(&i) else { return nil }
        let size = i.info.size, type = i.info.type
        var j = KeyData(); j.key = SMC.fourcc(k); j.info.size = size; j.data8 = 5
        guard call(&j), size <= 32 else { return nil }
        var b = j.bytes
        return (SMC.str(type), withUnsafeBytes(of: &b) { Array($0.prefix(Int(size))) })
    }
    func number(_ k: String) -> Double? {
        guard let (t, b) = read(k) else { return nil }
        switch t {
        case "flt " where b.count == 4: return Double(b.withUnsafeBytes { $0.load(as: Float.self) })
        case "ui8 ": return b.first.map(Double.init)
        case "ui16" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "fpe2" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78" where b.count == 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default: return nil
        }
    }
    /// 一次性枚举温度键（启动后在后台做一次）
    func enumerate() {
        guard !enumerated, conn != 0 else { return }; enumerated = true
        guard let c = read("#KEY")?.bytes else { return }
        let n = c.reduce(0) { $0 << 8 | Int($1) }
        for idx in 0..<min(n, 4000) {
            var i = KeyData(); i.data8 = 8; i.data32 = UInt32(idx)
            guard call(&i) else { continue }
            let k = SMC.str(i.key)
            if k.hasPrefix("Tp") || k.hasPrefix("Te") || k.hasPrefix("TC") { cpuKeys.append(k) }
            else if k.hasPrefix("Tg") || k.hasPrefix("TG") { gpuKeys.append(k) }
        }
        // 只保留能读出合理数值的键，并限制数量，降低每次采样的调用次数
        cpuKeys = Array(cpuKeys.filter { (number($0) ?? 0) > 15 }.prefix(16))
        gpuKeys = Array(gpuKeys.filter { (number($0) ?? 0) > 15 }.prefix(8))
    }
    func avgTemp(_ keys: [String]) -> Double? {
        let v = keys.compactMap { number($0) }.filter { $0 > 15 && $0 < 130 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    func fans() -> (rpm: [Double], min: Double, max: Double)? {
        guard let n = number("FNum"), n > 0 else { return nil }
        let rpm = (0..<Int(n)).map { number("F\($0)Ac") ?? 0 }
        return (rpm, number("F0Mn") ?? 0, number("F0Mx") ?? 0)
    }
}

// MARK: - HID 温度（SMC 不可用时的后备，使用公开 dylib 中的 IOHIDEventSystemClient）
enum HIDTemp {
    typealias CreateF = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatchF = @convention(c) (AnyObject, CFDictionary) -> Int32
    typealias CopySvcF = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyPropF = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvF = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias GetFloatF = @convention(c) (AnyObject, Int32) -> Double
    private static let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
    private static var services: [AnyObject]? = {
        guard let create: CreateF = sym("IOHIDEventSystemClientCreate"), let setm: SetMatchF = sym("IOHIDEventSystemClientSetMatching"),
              let copys: CopySvcF = sym("IOHIDEventSystemClientCopyServices"), let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = setm(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
        return copys(c)?.takeRetainedValue() as? [AnyObject]
    }()
    private static var client: AnyObject?
    static func cpuDie() -> Double? { read { $0.contains("tdie") }.max() }
    static func batteryTemp() -> Double? { let v = read { $0.contains("gas gauge battery") }; return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    static func read(_ match: (String) -> Bool) -> [Double] {
        guard let svcs = services, let prop: CopyPropF = sym("IOHIDServiceClientCopyProperty"), let ev: CopyEvF = sym("IOHIDServiceClientCopyEvent"), let gf: GetFloatF = sym("IOHIDEventGetFloatValue") else { return [] }
        var v: [Double] = []
        for s in svcs {
            guard let n = prop(s, "Product" as CFString)?.takeRetainedValue() as? String, match(n) else { continue }
            if let e = ev(s, 15, 0, 0)?.takeRetainedValue() { let t = gf(e, 15 << 16); if t > 5 && t < 130 { v.append(t) } }
        }
        return v
    }
}

// MARK: - 采样调度
final class Monitor: ObservableObject {
    static let shared = Monitor()
    @Published private(set) var s = Snapshot()
    @Published private(set) var cpuHist: [Double] = []
    @Published private(set) var gpuHist: [Double] = []
    @Published private(set) var upHist: [Double] = []
    @Published private(set) var downHist: [Double] = []
    @Published private(set) var interval: TimeInterval = 0
    static let detailInterval: TimeInterval = 2, lightInterval: TimeInterval = 5
    let histLen = 40
    var panelOpen = false { didSet { reschedule() } }
    var dashboardShown = false { didSet { reschedule() } }
    var mainWindowVisible: () -> Bool = { true }
    var menuBarEnabled = true { didSet { reschedule() } }
    var detail: Bool { panelOpen || (dashboardShown && mainWindowVisible()) }
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "monitor", qos: .utility)
    private var tick = 0
    private var started = false

    func start() {
        guard !started else { return }; started = true
        q.async {
            var x = Snapshot(); Readers.staticInfo(into: &x)
            _ = Readers.cpuUsage(); SMC.shared.enumerate()
            DispatchQueue.main.async { var y = self.s; y.chip = x.chip; y.ramGB = x.ramGB; y.osVersion = x.osVersion; y.pCores = x.pCores; y.eCores = x.eCores; y.gpuCores = x.gpuCores; self.s = y; self.reschedule() }
        }
    }
    /// 根据可见状态调整频率：面板/仪表盘可见 2 秒；只有菜单栏 5 秒；什么都不显示时停止
    func reschedule() {
        guard started else { return }
        let want: TimeInterval = detail ? Monitor.detailInterval : (menuBarEnabled ? Monitor.lightInterval : 0)
        if want == interval, timer != nil || want == 0 { return }
        timer?.cancel(); timer = nil; interval = want
        guard want > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: want, leeway: .milliseconds(Int(want * 200)))
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t; t.resume()
    }
    func sampleNow(full: Bool = true) { q.async { self.sample(forceFull: full) } }

    private func sample(forceFull: Bool = false) {
        let full = forceFull || DispatchQueue.main.sync { self.detail }
        var x = DispatchQueue.main.sync { self.s }
        x.cpu = Readers.cpuUsage()
        x.uptime = Readers.uptime()
        Readers.memory(into: &x)
        x.load = Readers.loadAvg()
        if full {
            tick += 1
            let smc = SMC.shared
            if tick % 3 == 1 {   // 温度、风扇变化慢，每 3 次采样读一次 SMC
                x.cpuTemp = smc.avgTemp(smc.cpuKeys) ?? HIDTemp.cpuDie()
                x.gpuTemp = smc.avgTemp(smc.gpuKeys)
                if let f = smc.fans() { x.fans = f.rpm; x.fanMin = f.min; x.fanMax = f.max } else { x.fans = nil }
            }
            let g = Readers.gpuInfo(); x.gpu = g.util
            Readers.network(into: &x)
            x.top = Readers.topProcesses()
            if tick % 5 == 1 { Readers.disk(into: &x); Readers.battery(into: &x); x.devices = Readers.devices() }
        } else if x.diskTotalGB == 0 { Readers.disk(into: &x) }
        let full2 = full
        DispatchQueue.main.async {
            self.s = x
            func push(_ a: inout [Double], _ v: Double) { a.append(v); if a.count > self.histLen { a.removeFirst(a.count - self.histLen) } }
            push(&self.cpuHist, x.cpu)
            if full2 { push(&self.gpuHist, x.gpu ?? 0); push(&self.upHist, x.upBps); push(&self.downHist, x.downBps) }
            self.onSample?(x)
        }
    }
    var onSample: ((Snapshot) -> Void)?
    /// 测试用：直接注入数据
    func inject(_ x: Snapshot, cpu: [Double], gpu: [Double], up: [Double], down: [Double]) { s = x; cpuHist = cpu; gpuHist = gpu; upHist = up; downHist = down }
}

// MARK: - 常亮 / 麦克风 / 截图
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published private(set) var on = false
    private var id: IOPMAssertionID = 0
    func toggle() { on ? stop() : startAssertion() }
    func startAssertion() {
        guard !on else { return }
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mac一键优化：保持常亮" as CFString, &id) == kIOReturnSuccess { on = true }
    }
    func stop() { if on { IOPMAssertionRelease(id); on = false } }
    /// 系统里本进程是否持有常亮断言（测试用）
    static func systemSeesAssertion() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return ((d[NSNumber(value: getpid())] ?? nil) ?? []).contains { ($0["AssertType"] as? String) == (kIOPMAssertionTypePreventUserIdleDisplaySleep as String) || ($0["AssertName"] as? String)?.contains("保持常亮") == true }
    }
}

enum Mic {
    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
    private static var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    static var available: Bool {
        guard let d = defaultInput() else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(d, &muteAddr) && AudioObjectIsPropertySettable(d, &muteAddr, &settable) == noErr && settable.boolValue
    }
    static var muted: Bool {
        guard let d = defaultInput() else { return false }
        var v: UInt32 = 0; var size = UInt32(4)
        return AudioObjectGetPropertyData(d, &muteAddr, 0, nil, &size, &v) == noErr && v == 1
    }
    @discardableResult static func setMuted(_ m: Bool) -> Bool {
        guard let d = defaultInput() else { return false }
        var v: UInt32 = m ? 1 : 0
        return AudioObjectSetPropertyData(d, &muteAddr, 0, nil, 4, &v) == noErr
    }
}

// MARK: - 累计清理统计（持久化）
final class CleanStats: ObservableObject {
    static var shared = CleanStats(defaults: .standard)
    let d: UserDefaults
    @Published private(set) var optimized: Int
    @Published private(set) var quitApps: Int
    @Published private(set) var freedMB: Double
    init(defaults: UserDefaults) {
        d = defaults
        optimized = d.integer(forKey: "stats.optimized"); quitApps = d.integer(forKey: "stats.quitApps"); freedMB = d.double(forKey: "stats.freedMB")
    }
    func addOptimized(_ n: Int) { DispatchQueue.main.async { self.optimized += n; self.d.set(self.optimized, forKey: "stats.optimized") } }
    func addQuit(memMB: Double) {
        DispatchQueue.main.async {
            self.quitApps += 1; self.freedMB += max(0, memMB)
            self.d.set(self.quitApps, forKey: "stats.quitApps"); self.d.set(self.freedMB, forKey: "stats.freedMB")
        }
    }
}
