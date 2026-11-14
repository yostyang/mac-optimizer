// 2.16 N9：分区上下比例、可识别版本的偏好、空间名称与目标缩略图
//
// 偏好：split.layout.v2 = [显示器 UUID: SplitLayoutV2 的 JSON]。旧键 split.customPct / split.custom / split.customRows 不删；
// 旧的 customRows 只写 1 / 2（旧版能表达的「平分 / 不分」），新比例只写进 v2，不塞进旧枚举字段。
// 回退旧版：旧版读旧键，看到的是它能表达的布局（栏宽 + 是否平分），不会识别新增的上下比例。
import SwiftUI
import AppKit

struct SplitLayoutV2: Codable, Equatable {
    var schemaVersion = 2
    var displayID: String
    var columnPercents: [Int]
    /// 每栏 [上, 下]；未拆分为空
    var rowPercentsByColumn: [[Int]]
    func isValid(for uuid: String) -> Bool {
        schemaVersion == 2 && displayID == uuid && SplitCustom.valid(columnPercents)
            && rowPercentsByColumn.count == columnPercents.count && rowPercentsByColumn.allSatisfy(SplitRows.valid)
    }
}

/// 上下比例（D4）：每个子区至少 20%，默认 50 / 50；拖动吸附 5%，键盘每步 5%（⇧ 1%）
enum SplitRows {
    static let minPct = 20, step = 5
    static let defaultSplit = [50, 50]
    static func valid(_ r: [Int]) -> Bool { r.isEmpty || (r.count == 2 && r.allSatisfy { $0 >= minPct } && r.reduce(0, +) == 100) }
    private static func clamp(_ top: Int) -> [Int] { let t = min(max(top, minPct), 100 - minPct); return [t, 100 - t] }
    /// 键盘：正数往下移（上区变大）。snap 时对齐到 5% 刻度
    static func move(_ r: [Int], by d: Int, snap: Bool = true) -> [Int] {
        guard r.count == 2, d != 0 else { return r }
        var top = r[0] + d
        if snap { top = d > 0 ? (r[0] / step + 1) * step : ((r[0] + step - 1) / step - 1) * step }
        return clamp(top)
    }
    /// 拖动：横线放到这一栏高度的 fraction（0 = 顶部）处
    static func drag(to fraction: CGFloat, snap: Bool = true) -> [Int] {
        let v = Double(fraction) * 100
        return clamp(Int(snap ? (v / Double(step)).rounded() * Double(step) : v.rounded()))
    }
    enum Input: Equatable { case ok([Int]), rejected(String) }
    /// 输入框：上区百分比。非整数、越界一律拒绝并说明可用范围
    static func parse(_ raw: String) -> Input {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let v = Int(s) else { return .rejected("请输入 \(minPct)–\(100 - minPct) 之间的整数") }
        guard (minPct...(100 - minPct)).contains(v) else { return .rejected("上方可设 \(minPct)%–\(100 - minPct)%：上下两区各至少 \(minPct)%") }
        return .ok([v, 100 - v])
    }
}

/// 区的空间名称：优先「左侧 1/3」「右侧 1/2 上方」，复杂比例用「右侧 30%」，同名时补区号
enum SplitNames {
    static func fraction(_ pct: Int) -> String {
        let known: [(Int, String)] = [(50, "1/2"), (33, "1/3"), (34, "1/3"), (67, "2/3"), (66, "2/3"), (25, "1/4"), (75, "3/4")]
        return known.first { $0.0 == pct }?.1 ?? "\(pct)%"
    }
    static func columnWord(_ i: Int, of n: Int) -> String {
        switch n {
        case 1: return "整屏"
        case 2: return i == 0 ? "左侧" : "右侧"
        case 3: return ["左侧", "中间", "右侧"][i]
        default: return i == 0 ? "左侧" : (i == n - 1 ? "右侧" : (i == 1 ? "左中" : "右中"))
        }
    }
    /// 全部区的名称，顺序与 SplitPrefs.zones 一致（从左到右、每栏从上到下）
    static func names(columns: [Int], rows: [[Int]]) -> [String] {
        var out: [String] = []
        for (i, c) in columns.enumerated() {
            let base = columnWord(i, of: columns.count) + " " + fraction(c)
            if rows.indices.contains(i), rows[i].count == 2 {
                let even = rows[i][0] == rows[i][1]
                out.append(base + " 上方" + (even ? "" : " \(rows[i][0])%"))
                out.append(base + " 下方" + (even ? "" : " \(rows[i][1])%"))
            } else { out.append(base) }
        }
        // 有歧义（同名）时补区号
        return out.enumerated().map { i, n in out.filter { $0 == n }.count > 1 ? n + "（第 \(i + 1) 区）" : n }
    }
    /// 固定模板与自定义统一换成百分比，便于命名
    static func columns(weights: [CGFloat]) -> [Int] { SplitCustom.percents(weights) }
}

/// 归位命令旁的布局缩略图：当前目标屏幕的全部区，高亮要放的那一个（与实际落区同一份 zones）
enum SplitThumb {
    static func image(zones: [CGRect], in visible: CGRect, highlight: Int?, size: CGSize = CGSize(width: 34, height: 22)) -> NSImage {
        let img = NSImage(size: size, flipped: false) { r in
            let k = min(r.width / max(visible.width, 1), r.height / max(visible.height, 1))
            let w = visible.width * k, h = visible.height * k
            let ox = (r.width - w) / 2, oy = (r.height - h) / 2
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: ox + 0.5, y: oy + 0.5, width: w - 1, height: h - 1), xRadius: 2, yRadius: 2); frame.lineWidth = 1; frame.stroke()
            for (i, z) in zones.enumerated() {
                let rr = NSRect(x: ox + (z.minX - visible.minX) * k, y: oy + (z.minY - visible.minY) * k, width: z.width * k, height: z.height * k).insetBy(dx: 0.5, dy: 0.5)
                (i == highlight ? NSColor(srgbRed: 0x58 / 255.0, green: 0x46 / 255.0, blue: 0xD6 / 255.0, alpha: 1) : NSColor.secondaryLabelColor.withAlphaComponent(0.22)).setFill()
                NSBezierPath(roundedRect: rr, xRadius: 1.2, yRadius: 1.2).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// 一个可执行的归位目标：名称、缩略图、实际矩形都来自同一份布局；执行前用签名核对布局没变
struct SplitZoneTarget {
    let display: SplitDisplay
    let index: Int
    let name: String
    let signature: String
    let thumb: NSImage
}

extension SplitController {
    /// 当前目标屏幕：要摆放的窗口所在的屏幕；读不到窗口时取第一块已启用分区的屏幕。
    /// 命令列表会随输入频繁刷新，这里用窗口列表（不需要辅助功能、不发 AX 请求）取位置；执行时仍用 AX 核对真实窗口。
    func targetDisplay() -> SplitDisplay? {
        if let tg = captured ?? tracker.lastExternal, let f = Self.frontWindowFrame(pid: tg.pid), let d = display(for: f), prefs.weights(d.uuid) != nil { return d }
        return screens.displays.first { prefs.weights($0.uuid) != nil }
    }
    /// 某应用最前面的普通窗口（CGWindowList 坐标与 AX 一样是主屏左上角原点、y 向下）
    static func frontWindowFrame(pid: pid_t) -> CGRect? {
        guard pid > 0, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in info where (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 40, r.height > 40 { return r }
        }
        return nil
    }
    func zoneTargets(for d: SplitDisplay) -> [SplitZoneTarget] {
        guard let ws = prefs.weights(d.uuid), let zs = prefs.zones(d.uuid, in: d.visible), let sig = prefs.signature(d.uuid) else { return [] }
        let names = SplitNames.names(columns: SplitNames.columns(weights: ws), rows: prefs.rowPercents(d.uuid))
        guard names.count == zs.count else { return [] }
        return zs.indices.map { SplitZoneTarget(display: d, index: $0, name: names[$0], signature: sig, thumb: SplitThumb.image(zones: zs, in: d.visible, highlight: $0)) }
    }
    /// 按命令里记下的布局执行：目标窗口所在屏幕或布局与命令生成时不同，就不执行旧区域
    @discardableResult
    func place(target t: SplitZoneTarget) -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let tg = captured ?? tracker.lastExternal else { return report("没有找到要移动的应用窗口") }
        guard let cur = driver.focusedFrame(pid: tg.pid) else { return report("「\(tg.name)」没有可移动的窗口") }
        guard let disp = display(for: cur), screens.displays.contains(where: { $0.uuid == t.display.uuid }) else { return report("目标屏幕已断开，没有移动窗口") }
        guard disp.uuid == t.display.uuid else { return report("「\(tg.name)」在另一块屏幕（\(disp.name)）上，没有移动；请在那块屏幕上重新选择分区") }
        guard prefs.signature(disp.uuid) == t.signature else { return report("这块屏幕的分区布局已经变化，没有移动窗口；请重新打开命令选择") }
        return place(index: t.index, label: t.name)
    }
}
