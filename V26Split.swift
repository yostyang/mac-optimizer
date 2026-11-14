import AppKit
import SwiftUI
import ApplicationServices

// MARK: - 2.6 桌面分区：纯逻辑
enum SplitTemplate: String, CaseIterable, Identifiable {
    case threeCol = "121", halves = "11", twoThirds = "21"
    var id: String { rawValue }
    var title: String { switch self { case .threeCol: return "1:2:1 三栏"; case .halves: return "左右平分"; case .twoThirds: return "2/3 + 1/3" } }
    var weights: [CGFloat] { switch self { case .threeCol: return [1, 2, 1]; case .halves: return [1, 1]; case .twoThirds: return [2, 1] } }
}
enum SplitZone: Int { case left = 0, center = 1, right = 2
    var title: String { ["左区", "中区", "右区"][rawValue] }
}

enum SplitLayout {
    static let gap: CGFloat = 8
    /// 在 visibleFrame（任意坐标系）内按权重切分，外边与区间都留 gap
    static func rects(_ t: SplitTemplate, in r: CGRect, gap g: CGFloat = gap) -> [CGRect] { rects(weights: t.weights, in: r, gap: g) }
    static func rects(weights w: [CGFloat], in r: CGRect, gap g: CGFloat = gap) -> [CGRect] {
        let n = CGFloat(w.count)
        let avail = r.width - g * (n + 1); let total = w.reduce(0, +)
        var x = r.minX + g; var out: [CGRect] = []
        for (i, wi) in w.enumerated() {
            var width = (avail * wi / total).rounded(.down)
            if i == w.count - 1 { width = r.maxX - g - x }
            out.append(CGRect(x: x, y: r.minY + g, width: width, height: r.height - 2 * g))
            x += width + g
        }
        return out
    }
    /// 每栏可再上下平分（rows[i] 为 1 或 2）；区的顺序是从左到右、每栏内从上到下。r 为 AppKit 坐标（y 向上）
    static func rects(weights w: [CGFloat], rows: [Int], in r: CGRect, gap g: CGFloat = gap, flipped: Bool = false) -> [CGRect] {
        rects(weights: w, in: r, gap: g).enumerated().flatMap { i, col -> [CGRect] in
            guard rows.indices.contains(i), rows[i] == 2 else { return [col] }
            let h = ((col.height - g) / 2).rounded(.down)
            let upper = CGRect(x: col.minX, y: col.maxY - h, width: col.width, height: h)
            let lower = CGRect(x: col.minX, y: col.minY, width: col.width, height: col.height - g - h)
            return flipped ? [lower, upper] : [upper, lower]   // flipped：y 向下的坐标系里 minY 才是上面
        }
    }
    /// 2.16：每栏按 [上, 下] 百分比拆分（空 = 不拆分）；50 / 50 时与上面的平分结果一致
    static func rects(weights w: [CGFloat], rowPercents rp: [[Int]], in r: CGRect, gap g: CGFloat = gap, flipped: Bool = false) -> [CGRect] {
        rects(weights: w, in: r, gap: g).enumerated().flatMap { i, col -> [CGRect] in
            guard rp.indices.contains(i), rp[i].count == 2, rp[i][0] + rp[i][1] > 0 else { return [col] }
            let avail = col.height - g
            let top = (avail * CGFloat(rp[i][0]) / CGFloat(rp[i][0] + rp[i][1])).rounded(.down)
            if flipped {   // y 向下：minY 一侧是上面
                return [CGRect(x: col.minX, y: col.minY, width: col.width, height: top),
                        CGRect(x: col.minX, y: col.minY + top + g, width: col.width, height: avail - top)]
            }
            return [CGRect(x: col.minX, y: col.maxY - top, width: col.width, height: top),
                    CGRect(x: col.minX, y: col.minY, width: col.width, height: avail - top)]
        }
    }
    /// 某一栏的第一个区在整个序列里的序号
    static func firstZone(ofColumn c: Int, rows: [Int]) -> Int { rows.prefix(c).reduce(0, +) }
    /// 区 → 矩形；两栏模板里“中区”不存在，右区 = 最后一栏
    static func rect(_ t: SplitTemplate, _ z: SplitZone, in r: CGRect) -> CGRect? {
        let rs = rects(t, in: r)
        switch z { case .left: return rs.first; case .right: return rs.last; case .center: return rs.count == 3 ? rs[1] : nil }
    }
    /// AppKit（左下原点、y 向上，主屏为基准）→ AX（主屏左上原点、y 向下）
    static func toAX(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
    static func fromAX(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect { toAX(r, primaryHeight: h) }

    enum Outcome: String { case ok = "已归位", sizeLimited = "尺寸受应用限制", notMovable = "此窗口不可移动" }
    static func classify(target t: CGRect, actual a: CGRect?, tol: CGFloat = 2) -> Outcome {
        guard let a = a else { return .notMovable }
        let posOK = abs(a.minX - t.minX) <= tol && abs(a.minY - t.minY) <= tol
        let sizeOK = abs(a.width - t.width) <= tol && abs(a.height - t.height) <= tol
        if posOK && sizeOK { return .ok }
        if posOK || abs(a.minX - t.minX) <= 40 { return .sizeLimited }
        return .notMovable
    }
}

// MARK: - 显示器
struct SplitDisplay: Equatable { let uuid: String; let name: String; let visible: CGRect; let scale: CGFloat }
protocol SplitScreens { var displays: [SplitDisplay] { get }; var primaryHeight: CGFloat { get } }
struct SystemScreens: SplitScreens {
    var displays: [SplitDisplay] {
        NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
            return SplitDisplay(uuid: CFUUIDCreateString(nil, u) as String, name: s.localizedName,
                                visible: s.visibleFrame, scale: s.backingScaleFactor)
        }
    }
    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

// MARK: - 窗口（可注入，测试用假实现）
struct SplitTarget: Equatable { let pid: pid_t; let name: String }
/// 记录最近一次激活的“非本 App”应用（只观察通知，不轮询）
protocol SplitAppTracker { var lastExternal: SplitTarget? { get }; func reactivate(_ t: SplitTarget) }
final class SystemAppTracker: SplitAppTracker {
    private(set) var lastExternal: SplitTarget?
    private var obs: NSObjectProtocol?
    init() {
        if let a = NSWorkspace.shared.frontmostApplication { note(a) }
        obs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.note(a) }
        }
    }
    private func note(_ a: NSRunningApplication) {
        guard a.processIdentifier != getpid(), a.activationPolicy == .regular else { return }
        lastExternal = SplitTarget(pid: a.processIdentifier, name: a.localizedName ?? "前台应用")
    }
    func reactivate(_ t: SplitTarget) { NSRunningApplication(processIdentifier: t.pid)?.activate(options: []) }
}

protocol SplitWindowDriver {
    func trusted() -> Bool
    func focusedFrame(pid: pid_t) -> CGRect?  // AX 坐标；同时把该窗口设为下一次 setFocused 的对象
    var armedWindow: AnyObject? { get }       // 当前选中的具体窗口（撤销用）
    func arm(_ window: AnyObject) -> CGRect?  // 重新选中一个具体窗口；窗口已关闭返回 nil
    func setFocused(_ r: CGRect) -> CGRect? // 返回读回
}
final class AXWindowDriver: SplitWindowDriver {
    private var lastWin: AXUIElement?
    func trusted() -> Bool { AXIsProcessTrusted() }
    private func window(_ pid: pid_t) -> AXUIElement? {
        guard trusted(), pid != getpid() else { return nil }
        let a = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(a, attr as CFString, &v) == .success, let w = v, CFGetTypeID(w) == AXUIElementGetTypeID() { return (w as! AXUIElement) }
        }
        var ws: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &ws) == .success, let arr = ws as? [AXUIElement] else { return nil }
        return arr.first { w in
            var s: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &s) == .success && (s as? String) == (kAXStandardWindowSubrole as String)
        }
    }
    private func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?; var pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    var armedWindow: AnyObject? { lastWin }
    func arm(_ window: AnyObject) -> CGRect? {
        guard trusted(), CFGetTypeID(window) == AXUIElementGetTypeID() else { lastWin = nil; return nil }
        let w = window as! AXUIElement
        guard let f = frame(w) else { lastWin = nil; return nil }
        lastWin = w; return f
    }
    func focusedFrame(pid: pid_t) -> CGRect? { lastWin = nil; guard let w = window(pid) else { return nil }; lastWin = w; return frame(w) }
    func setFocused(_ r: CGRect) -> CGRect? {
        guard let w = lastWin else { return nil }
        var pt = r.origin, sz = r.size
        if let pv = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        let out = frame(w); lastWin = nil; return out
    }
}

// MARK: - 偏好（按显示器 UUID，默认关闭）
struct SplitPrefs {
    let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }
    private let key = "split.templates"
    func template(_ uuid: String) -> SplitTemplate? {
        (d.dictionary(forKey: key) as? [String: String])?[uuid].flatMap(SplitTemplate.init(rawValue:))
    }
    func set(_ t: SplitTemplate?, for uuid: String) {
        var m = (d.dictionary(forKey: key) as? [String: String]) ?? [:]
        m[uuid] = t?.rawValue; d.set(m, forKey: key)
        for k in [customKey, legacyCustomKey] {
            var c = (d.dictionary(forKey: k) as? [String: [Int]]) ?? [:]
            if c.removeValue(forKey: uuid) != nil { d.set(c, forKey: k) }
        }
        removeV2(uuid)
    }
    // 自定义比例：每块屏幕 2–4 栏，与固定模板二选一。
    // 2.14 起存百分比（split.customPct）；2.10–2.13 的 1–9 权重（split.custom）读取时换算，旧键不删，便于回退旧版。
    private let customKey = "split.customPct", legacyCustomKey = "split.custom"
    func custom(_ uuid: String) -> [Int]? {
        if let v = v2(uuid) { return v.columnPercents }   // 2.16：带版本的新数据优先
        if let p = (d.dictionary(forKey: customKey) as? [String: [Int]])?[uuid], SplitCustom.valid(p) { return p }
        guard let w = (d.dictionary(forKey: legacyCustomKey) as? [String: [Int]])?[uuid],
              SplitCustom.columns.contains(w.count), w.allSatisfy({ (1...9).contains($0) }) else { return nil }
        return SplitCustom.percents(w.map { CGFloat($0) })
    }
    func setCustom(_ p: [Int], for uuid: String) {
        guard SplitCustom.valid(p) else { return }
        // 2.16：已有的上下比例按栏保留，新增的栏不拆分。
        // 必须在改写栏宽之前取旧比例：v2 只在 columnPercents 与 split.customPct 一致时才算数，
        // 先写宽度会让旧 v2 失效，读出来就成了「都不拆分」。
        let old = rowPercents(uuid)
        var m = (d.dictionary(forKey: key) as? [String: String]) ?? [:]
        m[uuid] = nil; d.set(m, forKey: key)
        var c = (d.dictionary(forKey: customKey) as? [String: [Int]]) ?? [:]
        c[uuid] = p; d.set(c, forKey: customKey)
        writeV2(SplitLayoutV2(displayID: uuid, columnPercents: p, rowPercentsByColumn: p.indices.map { old.indices.contains($0) ? old[$0] : [] }))
    }
    /// 这块屏幕当前生效的各栏权重（固定模板或自定义）；未启用返回 nil
    func weights(_ uuid: String) -> [CGFloat]? { template(uuid)?.weights ?? custom(uuid)?.map { CGFloat($0) } }
    // 2.10：自定义模板里每栏是否上下平分；只对自定义比例有效
    private let rowsKey = "split.customRows"
    /// 每栏几个区（1 或 2），由上下比例推出；固定模板一律 1
    func rows(_ uuid: String) -> [Int] {
        guard let n = weights(uuid)?.count else { return [] }
        let rp = rowPercents(uuid)
        return (0..<n).map { rp.indices.contains($0) && rp[$0].count == 2 ? 2 : 1 }
    }
    /// 2.16 N9：每栏上下比例（[上, 下]，未拆分为空）。新数据优先；没有时读 2.10–2.15 的 split.customRows（平分 → [50, 50]）
    func rowPercents(_ uuid: String) -> [[Int]] {
        guard let cols = custom(uuid), template(uuid) == nil else { return [] }
        if let v = v2(uuid) { return v.rowPercentsByColumn }
        guard let r = (d.dictionary(forKey: rowsKey) as? [String: [Int]])?[uuid], r.count == cols.count, r.allSatisfy({ $0 == 1 || $0 == 2 }) else {
            return Array(repeating: [], count: cols.count)
        }
        return r.map { $0 == 2 ? [50, 50] : [] }
    }
    /// 旧接口：按 1 / 2 设置是否拆分。已拆分的栏保留原比例，新拆分的栏默认 50 / 50；栏数对不上按都不拆分
    func setRows(_ r: [Int], for uuid: String) {
        var m = (d.dictionary(forKey: rowsKey) as? [String: [Int]]) ?? [:]
        m[uuid] = r.map { $0 == 2 ? 2 : 1 }; d.set(m, forKey: rowsKey)
        guard let cols = custom(uuid) else { return }
        let old = rowPercents(uuid)
        let rp: [[Int]] = r.count == cols.count
            ? r.indices.map { i in r[i] == 2 ? (old.indices.contains(i) && old[i].count == 2 ? old[i] : [50, 50]) : [] }
            : Array(repeating: [], count: cols.count)
        writeV2(SplitLayoutV2(displayID: uuid, columnPercents: cols, rowPercentsByColumn: rp))
    }
    /// 设置某一栏的上下比例（nil = 不拆分）。比例不合法时不保存并返回 false
    @discardableResult func setRowPercents(_ value: [Int]?, column i: Int, for uuid: String) -> Bool {
        guard let cols = custom(uuid), cols.indices.contains(i) else { return false }
        if let v = value, !SplitRows.valid(v) { return false }
        var rp = rowPercents(uuid); if rp.count != cols.count { rp = Array(repeating: [], count: cols.count) }
        rp[i] = value ?? []
        writeV2(SplitLayoutV2(displayID: uuid, columnPercents: cols, rowPercentsByColumn: rp))
        // 旧版只能表达「平分 / 不分」：旧键只写 1 / 2，不写新比例
        var m = (d.dictionary(forKey: rowsKey) as? [String: [Int]]) ?? [:]
        m[uuid] = rp.map { $0.count == 2 ? 2 : 1 }; d.set(m, forKey: rowsKey)
        return rowPercents(uuid) == rp
    }
    /// D5：「恢复默认比例」只作用于这块屏幕：两栏 50 / 50、不上下拆分，仍保持自定义布局启用；间距与其他屏幕不动，不移动窗口
    func resetCustom(_ uuid: String) {
        setCustom([50, 50], for: uuid)
        writeV2(SplitLayoutV2(displayID: uuid, columnPercents: [50, 50], rowPercentsByColumn: [[], []]))
        var m = (d.dictionary(forKey: rowsKey) as? [String: [Int]]) ?? [:]
        m[uuid] = [1, 1]; d.set(m, forKey: rowsKey)
    }
    // MARK: 2.16 带版本的分区数据（split.layout.v2：[显示器 UUID: JSON]）
    private let v2Key = "split.layout.v2"
    private func v2Raw(_ uuid: String) -> Data? { (d.dictionary(forKey: v2Key) as? [String: Data])?[uuid] }
    private func decodeV2(_ uuid: String) -> SplitLayoutV2? {
        guard let data = v2Raw(uuid), let v = try? JSONDecoder().decode(SplitLayoutV2.self, from: data), v.isValid(for: uuid) else { return nil }
        return v
    }
    /// 新数据只在与 split.customPct 一致时采用：回退旧版改过宽度后再升级，以旧版最后保存的为准（上下比例回到旧键的平分）
    func v2(_ uuid: String) -> SplitLayoutV2? {
        guard let v = decodeV2(uuid) else { return nil }
        if let p = (d.dictionary(forKey: customKey) as? [String: [Int]])?[uuid], p != v.columnPercents { return nil }
        return v
    }
    /// 新数据存在但无法识别（版本不对、比例不合法、不是这块屏幕的）：界面提示并提供恢复默认，不静默覆盖
    func v2Invalid(_ uuid: String) -> Bool { v2Raw(uuid) != nil && decodeV2(uuid) == nil }
    private func writeV2(_ v: SplitLayoutV2) {
        guard v.isValid(for: v.displayID), let data = try? JSONEncoder().encode(v) else { return }
        var m = (d.dictionary(forKey: v2Key) as? [String: Data]) ?? [:]
        m[v.displayID] = data; d.set(m, forKey: v2Key)   // 只改这块屏幕的条目
    }
    private func removeV2(_ uuid: String) {
        var m = (d.dictionary(forKey: v2Key) as? [String: Data]) ?? [:]
        if m.removeValue(forKey: uuid) != nil { d.set(m, forKey: v2Key) }
    }
    // 2.10：窗口之间和屏幕边缘的间距（所有屏幕共用），0–24 pt
    private let gapKey = "split.gap"
    static let gapRange = 0...24
    var gap: CGFloat {
        guard let v = d.object(forKey: gapKey) as? Int else { return SplitLayout.gap }
        return CGFloat(min(max(v, Self.gapRange.lowerBound), Self.gapRange.upperBound))
    }
    func setGap(_ v: Int) { d.set(min(max(v, Self.gapRange.lowerBound), Self.gapRange.upperBound), forKey: gapKey) }
    /// 这块屏幕的全部区（AppKit 坐标），唯一入口：模板或自定义比例 + 上下平分 + 间距
    func zones(_ uuid: String, in visible: CGRect) -> [CGRect]? {
        guard let ws = weights(uuid) else { return nil }
        return SplitLayout.rects(weights: ws, rowPercents: rowPercents(uuid), in: visible, gap: gap)
    }
    func title(_ uuid: String) -> String? { template(uuid)?.title ?? custom(uuid).map { "自定义 " + SplitCustom.title($0) } }
    /// 布局签名：命令生成时记下，执行前核对（屏幕断连或布局变化后不执行旧区域）
    func signature(_ uuid: String) -> String? {
        guard let ws = weights(uuid) else { return nil }
        return uuid + "|" + ws.map { String(Int($0 * 1000)) }.joined(separator: ",") + "|" + rowPercents(uuid).map { $0.map(String.init).joined(separator: "/") }.joined(separator: ",")
    }
}

// MARK: - 控制器
final class SplitController: ObservableObject {
    static let shared = SplitController()
    var screens: SplitScreens = SystemScreens()
    var driver: SplitWindowDriver = AXWindowDriver()
    var prefs = SplitPrefs()
    lazy var tracker: SplitAppTracker = SystemAppTracker()
    var captured: SplitTarget?          // 打开命令面板时记下的目标应用
    func capture() { captured = tracker.lastExternal }
    @Published var last: String = ""
    private(set) var undo: CGRect?   // 一步撤销（AX 坐标）
    private var undoTarget: SplitTarget?
    private var undoWindow: AnyObject?

    /// 窗口中心所在显示器（AX 坐标比较）
    func display(for axFrame: CGRect) -> SplitDisplay? {
        let h = screens.primaryHeight
        let c = CGPoint(x: axFrame.midX, y: axFrame.midY)
        return screens.displays.first { SplitLayout.toAX($0.visible, primaryHeight: h).contains(c) } ?? screens.displays.first
    }

    @discardableResult
    func place(_ z: SplitZone) -> String { place(zone: z, index: nil) }
    /// 按序号放（从 0 起）：四栏时中间两栏用这个
    @discardableResult
    func place(index: Int) -> String { place(zone: nil, index: index) }
    /// 2.16：带空间名称的序号归位（名称来自与实际落区同一份布局）
    @discardableResult
    func place(index: Int, label: String) -> String { place(zone: nil, index: index, label: label) }
    private func place(zone: SplitZone?, index: Int?, label name: String? = nil) -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let tg = captured ?? tracker.lastExternal else { return report("没有找到要移动的应用窗口") }
        captured = nil
        guard let cur = driver.focusedFrame(pid: tg.pid) else { return report("「\(tg.name)」没有可移动的窗口") }
        let win = driver.armedWindow
        guard let disp = display(for: cur) else { return report("没有检测到显示器") }
        guard let rs = prefs.zones(disp.uuid, in: disp.visible) else { return report("这块屏幕还没选分区模板") }
        let rows = prefs.rows(disp.uuid)
        let label = name ?? zone?.title ?? "第 \((index ?? 0) + 1) 区"
        // 左/中/右按栏算；某栏上下平分时指它上面的那个区
        let i: Int? = { switch zone {
            case .left: return 0
            case .right: return SplitLayout.firstZone(ofColumn: rows.count - 1, rows: rows)
            case .center: return rows.count == 3 ? SplitLayout.firstZone(ofColumn: 1, rows: rows) : nil
            case nil: return index } }()
        guard let i, rs.indices.contains(i) else { return report("当前模板没有\(label)") }
        let r = rs[i]
        let target = SplitLayout.toAX(r, primaryHeight: screens.primaryHeight)
        let got = driver.setFocused(target)
        let o = SplitLayout.classify(target: target, actual: got)
        if o != .notMovable { undo = cur; undoTarget = tg; undoWindow = win }
        tracker.reactivate(tg)
        switch o {
        case .ok: return report("已把 \(tg.name) 放到\(label)")
        case .sizeLimited: return report("已把 \(tg.name) 移到\(label)，但窗口没有缩到这个区的大小（尺寸受应用限制）")
        case .notMovable: return report("「\(tg.name)」的窗口不可移动")
        }
    }
    @discardableResult
    func undoLast() -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let u = undo, let tg = undoTarget else { return report("没有可撤销的归位") }
        captured = nil
        // 撤销只作用于当初移动的那个具体窗口，不按应用重新取焦点窗口（同一应用多窗口时不会错移）
        guard let win = undoWindow, driver.arm(win) != nil else {
            undo = nil; undoTarget = nil; undoWindow = nil
            return report("「\(tg.name)」原来的窗口已关闭，无法撤销")
        }
        _ = driver.setFocused(u); undo = nil; undoTarget = nil; undoWindow = nil
        tracker.reactivate(tg)
        return report("已把 \(tg.name) 撤销归位")
    }
    func rememberUndo(frame: CGRect, target: SplitTarget, window: AnyObject?) { undo = frame; undoTarget = target; undoWindow = window }
    func report(_ s: String) -> String { DispatchQueue.main.async { self.last = s }; return s }

    static func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    static func commands(_ q: String) -> [CmdItem] {
        var out: [CmdItem] = []
        let sc = SplitController.shared
        // 2.16 N9：按目标屏幕的实际布局列出每个区，名称用空间描述，旁边是高亮目标区的缩略图；
        // 执行时核对屏幕与布局签名，变化了就不执行旧区域
        if let d = sc.targetDisplay() {
            let targets = sc.zoneTargets(for: d)
            let rows = sc.prefs.rows(d.uuid)
            let firstRight = rows.isEmpty ? -1 : SplitLayout.firstZone(ofColumn: rows.count - 1, rows: rows)
            let center = rows.count == 3 ? SplitLayout.firstZone(ofColumn: 1, rows: rows) : -1
            for t in targets {
                // 旧说法（左区 / 中区 / 右区 / 第 n 区）仍可搜到对应的区
                var alias = "放到第 \(t.index + 1) 区 第\(t.index + 1)区"
                if t.index == 0 { alias += " 放到左区" }
                if t.index == firstRight { alias += " 放到右区" }
                if t.index == center { alias += " 放到中区" }
                guard CmdIndex.matches(q, "放到\(t.name) \(alias) 分区 分屏 窗口 split") else { continue }
                out.append(CmdItem(id: "split.z\(t.index)", kind: .action, title: "放到\(t.name)", subtitle: "\(d.name) · 第 \(t.index + 1) 区",
                                   symbol: "rectangle.split.3x1", icon: t.thumb, actions: [CmdAction(title: "放到\(t.name)", hint: "↵", run: {
                                       StatusBar.shared.popover.performClose(nil); SplitHUD.show(SplitController.shared.place(target: t))
                                   })]))
            }
        } else {
            for z in [SplitZone.left, .center, .right] where CmdIndex.matches(q, "放到\(z.title) 分区 分屏 窗口 split") {
                out.append(CmdItem(id: "split.\(z.rawValue)", kind: .action, title: "放到\(z.title)", subtitle: "把前台窗口放进当前屏幕的分区",
                                   symbol: "rectangle.split.3x1", actions: [CmdAction(title: "放到\(z.title)", hint: "↵", run: {
                                       StatusBar.shared.popover.performClose(nil); SplitHUD.show(SplitController.shared.place(z))
                                   })]))
            }
        }
        if CmdIndex.matches(q, "撤销归位 撤销 分区 分屏 undo") {
            out.append(CmdItem(id: "split.undo", kind: .action, title: "撤销归位", subtitle: "把上次移动的窗口放回原处",
                               symbol: "arrow.uturn.backward", actions: [CmdAction(title: "撤销归位", hint: "↵", run: {
                                   SplitHUD.show(SplitController.shared.undoLast())
                               })]))
        }
        return out
    }
}

// MARK: - 结果提示：主窗口可见用 Toast，否则用不抢焦点的浮层
enum SplitHUD {
    static var panel: NSPanel?
    static var sink: ((String) -> Void)?   // 测试用
    static func show(_ text: String) {
        if let sink { sink(text); return }
        let ok = text.hasPrefix("已")
        ToastCenter.shared.show(text, symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", tint: ok ? good : warn)
        if NSApp.windows.contains(where: { $0.isVisible && $0.isMainWindow && !($0 is NSPanel) }) { return }
        let p = panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = p
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let v = NSHostingView(rootView: Text(text).font(DS.body(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))).fixedSize())
        p.contentView = v; p.setContentSize(v.fittingSize)
        if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - v.fittingSize.width / 2, y: f.minY + 80)) }
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { p.orderOut(nil) }
    }
}

// MARK: - 页面
struct SplitPage: View {
    @ObservedObject var c = SplitController.shared
    @State private var sel: String?
    @State private var tick = 0
    var body: some View {
        let ds = c.screens.displays
        let trusted = c.driver.trusted()
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "桌面分区", sub: "为每块屏幕选模板，再用 ⌘K 把前台窗口放进分区") { EmptyView() }
            if !trusted {
                StateLine(kind: .unknown, text: "需要“辅助功能”权限才能移动窗口", detail: "未授权时分区命令不可用；授权后回到这里即可使用。",
                          actions: [StateAction(title: "打开系统设置", symbol: "gearshape") { SplitController.openAXSettings() }], id: "split.grant")
                    .padding(10).background(RoundedRectangle(cornerRadius: DS.r.card).fill(warn.opacity(0.1)))
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 2) {
                    ForEach(ds, id: \.uuid) { d in
                        ListRow(icon: nil, symbol: "display", title: d.name,
                                subtitle: c.prefs.title(d.uuid) ?? "未启用",
                                selected: (sel ?? ds.first?.uuid) == d.uuid, action: { sel = d.uuid }) { EmptyView() }.accessibilityIdentifier("split.row.\(d.uuid)")
                    }
                }.frame(width: 220).accessibilityElement(children: .contain).accessibilityIdentifier("split.list")
                if let d = ds.first(where: { $0.uuid == (sel ?? ds.first?.uuid) }) {
                    detail(d).id(tick)
                } else { StateLine(kind: .empty, text: "没有检测到显示器", actions: [.refresh { tick += 1 }], id: "split.state") }
            }
            Spacer()
        }.padding(20)
    }
    @ViewBuilder func detail(_ d: SplitDisplay) -> some View {
        let cur = c.prefs.template(d.uuid)
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "模板")
            ForEach(SplitTemplate.allCases) { t in
                Button(action: { c.prefs.set(t, for: d.uuid); tick += 1 }) {
                    HStack {
                        preview(t).frame(width: 96, height: 40)
                        Text(t.title); Spacer()
                        if cur == t { Image(systemName: "checkmark").foregroundColor(accent) }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("split.tpl.\(t.rawValue)")
            }
            SplitCustomEditor(uuid: d.uuid, prefs: c.prefs, changed: { tick += 1 })
            SplitGapEditor(prefs: c.prefs, changed: { tick += 1 })
            Button("关闭分区") { c.prefs.set(nil, for: d.uuid); tick += 1 }
                .disabled(c.prefs.weights(d.uuid) == nil).accessibilityIdentifier("split.off")
            Text(String(format: "可用区域 %.0f×%.0f pt · %.0fx", d.visible.width, d.visible.height, d.scale))
                .font(DS.sub()).foregroundColor(DS.text.secondary)
            Divider()
            Text("把窗口放进分区").font(DS.sub(.semibold))
            Text("选好模板或自定义比例后，切到要摆放的窗口，按 ⌘K 选目标分区；也可以打开下面的开关，按住 ⇧ 把窗口拖进分区。只移动你选中的窗口，完成后可撤销。")
                .font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("split.howto")
            SplitDragToggle()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func preview(_ t: SplitTemplate) -> some View { SplitPreview(weights: t.weights) }
}
