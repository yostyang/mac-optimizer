// 2.10：自定义分区比例、拖动到分区的开关、清理记录恢复
import SwiftUI
import AppKit

// MARK: - 自定义比例（2.14 起为百分比：每栏整数百分比、合计 100、单栏至少 10%）
enum SplitCustom {
    static let columns = 2...4
    static let minPct = 10, step = 5
    static func valid(_ p: [Int]) -> Bool { columns.contains(p.count) && p.allSatisfy { $0 >= minPct } && p.reduce(0, +) == 100 }
    static func title(_ p: [Int]) -> String { p.map { "\($0)%" }.joined(separator: " : ") }
    /// 任意比例换成百分比：最大余数法凑满 100，再把低于下限的栏补到 10%（从最宽的栏里扣）
    static func percents(_ w: [CGFloat]) -> [Int] {
        let total = w.reduce(0, +)
        guard columns.contains(w.count), total > 0, w.allSatisfy({ $0 > 0 }) else { return [50, 50] }
        let raw = w.map { Double($0 / total) * 100 }
        var out = raw.map { Int($0.rounded(.down)) }
        // 余数相同按从左到右（sorted 不保证稳定，结果要可重复）
        let order = raw.indices.sorted { a, b in
            let ra = raw[a] - Double(out[a]), rb = raw[b] - Double(out[b])
            return abs(ra - rb) > 1e-9 ? ra > rb : a < b
        }
        for i in order.prefix(100 - out.reduce(0, +)) { out[i] += 1 }
        for i in out.indices where out[i] < minPct {
            let need = minPct - out[i]; out[i] = minPct
            if let j = out.indices.max(by: { out[$0] < out[$1] }) { out[j] -= need }
        }
        return out
    }
    /// 进入自定义时的起点：沿用当前模板的比例，没有就从 50 : 50 开始
    static func seed(from weights: [CGFloat]?) -> [Int] { percents(weights ?? [1, 1]) }
    /// 拖动或键盘调第 i 条分隔线（左边是第 i 栏，右边是第 i+1 栏），两栏合计不变
    /// - snap：按 5% 对齐（键盘每次 5%、拖动吸附）；false 时按 1% 调整
    static func moveDivider(_ p: [Int], _ i: Int, by d: Int, snap: Bool = true) -> [Int] {
        guard p.indices.contains(i), p.indices.contains(i + 1), d != 0 else { return p }
        var left = p[i] + d
        if snap { left = d > 0 ? (p[i] / step + 1) * step : ((p[i] + step - 1) / step - 1) * step }
        return setDivider(p, i, left: left)
    }
    /// 拖动：分隔线放到整块宽度的 fraction（0–1）处
    static func dragDivider(_ p: [Int], _ i: Int, to fraction: CGFloat, snap: Bool = true) -> [Int] {
        guard p.indices.contains(i), p.indices.contains(i + 1) else { return p }
        let before = p[..<i].reduce(0, +)
        var left = Double(fraction) * 100 - Double(before)
        left = snap ? (left / Double(step)).rounded() * Double(step) : left.rounded()
        return setDivider(p, i, left: Int(left))
    }
    private static func setDivider(_ p: [Int], _ i: Int, left: Int) -> [Int] {
        let pair = p[i] + p[i + 1]
        var out = p; out[i] = min(max(left, minPct), pair - minPct); out[i + 1] = pair - out[i]
        return out
    }
    /// 输入框：把第 i 栏设成 v，差额由右边相邻栏补（最后一栏由左边相邻栏补）；放不下就拒绝并说明原因
    enum Input: Equatable { case ok([Int]), rejected(String) }
    static func set(_ p: [Int], column i: Int, to v: Int) -> Input {
        guard p.indices.contains(i), p.count >= 2 else { return .rejected("没有第 \(i + 1) 栏") }
        let j = i + 1 < p.count ? i + 1 : i - 1
        let maxV = p[i] + p[j] - minPct
        guard v >= minPct else { return .rejected("每栏至少 \(minPct)%") }
        guard v <= maxV else { return .rejected("第 \(i + 1) 栏最多 \(maxV)%：第 \(j + 1) 栏至少要留 \(minPct)%") }
        var out = p; out[j] -= v - p[i]; out[i] = v
        return .ok(out)
    }
    /// 加一栏：新栏取平均宽度，其余按原比例让出
    static func addColumn(_ p: [Int]) -> [Int] {
        guard p.count < columns.upperBound else { return p }
        return percents(p.map { CGFloat($0) } + [CGFloat(100) / CGFloat(p.count)])
    }
    /// 减一栏：去掉最后一栏，其余按原比例放大
    static func removeColumn(_ p: [Int]) -> [Int] { p.count > columns.lowerBound ? percents(p.dropLast().map { CGFloat($0) }) : p }
}

struct SplitPreview: View {
    let weights: [CGFloat]
    var rows: [Int] = []
    var body: some View {
        GeometryReader { g in
            ForEach(Array(SplitLayout.rects(weights: weights, rows: rows, in: CGRect(origin: .zero, size: g.size), gap: 3, flipped: true).enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.35)).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
        }.background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }
}

// 比例编辑器见 SplitRatioEditor.swift（2.14）
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

/// 分区间距：窗口之间和屏幕边缘留多少空
struct SplitGapEditor: View {
    let prefs: SplitPrefs
    let changed: () -> Void
    var body: some View {
        let g = Int(prefs.gap)
        HStack(spacing: 6) {
            Text("间距").font(DS.sub())
            Button(action: { prefs.setGap(g - 2); changed() }) { Image(systemName: "minus") }
                .disabled(g <= SplitPrefs.gapRange.lowerBound).accessibilityIdentifier("split.gap.minus").accessibilityLabel("减小间距")
            Text("\(g) pt").font(DS.sub(.semibold)).monospacedDigit().frame(minWidth: 34).accessibilityIdentifier("split.gap.value")
            Button(action: { prefs.setGap(g + 2); changed() }) { Image(systemName: "plus") }
                .disabled(g >= SplitPrefs.gapRange.upperBound).accessibilityIdentifier("split.gap.plus").accessibilityLabel("增大间距")
            Text("窗口之间和屏幕边缘的留空，所有屏幕共用；0 为紧贴。").font(DS.sub()).foregroundColor(DS.text.secondary)
        }.controlSize(.small)
    }
}

/// 拖动到分区的开关（默认关闭）
struct SplitDragToggle: View {
    @AppStorage(DragZones.prefKey) private var on = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("按住 ⇧ 拖动窗口时显示分区", isOn: Binding(get: { on }, set: { v in
                on = v
                if MOTests.active { return }   // 测试不启动全局鼠标监听
                if v { DragZones.shared.start() } else { DragZones.shared.stop() }
            })).accessibilityIdentifier("split.drag")
            Text("按住 ⇧ 拖窗口的标题栏，屏幕上会出现分区；在某个区里松手，窗口就放进去。不按 ⇧ 时没有任何影响，归位后可用 ⌘K 撤销。")
                .font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 清理记录恢复
enum CleanRestore {
    enum Status: Equatable { case available, restored, trashGone, untracked }
    enum Outcome: Equatable {
        case restored(String)            // 放回原位置
        case renamed(String)             // 原位置已有同名文件：改名放回
        case failed(String)
        var message: String {
            switch self {
            case .restored(let p): return "已恢复到原位置：" + (p as NSString).lastPathComponent
            case .renamed(let p): return "已恢复，原位置有同名文件，改名为「" + (p as NSString).lastPathComponent + "」"
            case .failed(let why): return why
            }
        }
    }
    static func status(_ r: CleanRecord, fm: FileManager = .default) -> Status {
        if r.restored == true { return .restored }
        guard let t = r.trashPath else { return .untracked }      // 旧版记录没有记下废纸篓位置
        return fm.fileExists(atPath: t) ? .available : .trashGone
    }
    /// 不覆盖已有文件：「报告.pdf」→「报告（恢复）.pdf」→「报告（恢复 2）.pdf」
    static func freePath(_ path: String, fm: FileManager = .default) -> String {
        guard fm.fileExists(atPath: path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension, base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 1...99 {
            let cand = (dir as NSString).appendingPathComponent(base + (n == 1 ? "（恢复）" : "（恢复 \(n)）") + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: cand) { return cand }
        }
        return (dir as NSString).appendingPathComponent(base + "（恢复 \(UUID().uuidString.prefix(6))）" + (ext.isEmpty ? "" : "." + ext))
    }
    static func restore(_ r: CleanRecord, fm: FileManager = .default) -> Outcome {
        switch status(r, fm: fm) {
        case .restored: return .failed("这一项已经恢复过了")
        case .untracked: return .failed("旧版记录没有保存废纸篓位置，请到废纸篓里手动放回")
        case .trashGone: return .failed("废纸篓里已经找不到这一项（可能已清倒或被移走），无法恢复")
        case .available: break
        }
        guard let t = r.trashPath else { return .failed("无法恢复") }
        let dest = freePath(r.path, fm: fm)
        do {
            // 原目录已不存在时重新创建
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: t, toPath: dest)
            return dest == r.path ? .restored(dest) : .renamed(dest)
        } catch { return .failed("恢复失败：\(error.localizedDescription)") }
    }
}

extension CleanStore {
    @discardableResult func restore(_ r: CleanRecord) -> CleanRestore.Outcome {
        let o = CleanRestore.restore(r)
        restoreNote = o.message
        if case .failed = o { return o }
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i].restored = true }
        if !saveRecords() { restoreNote += "（记录未保存：\(saveError)）" }
        ChangeLog.shared.add(kind: .clean, title: "从废纸篓恢复：" + (r.path as NSString).lastPathComponent, detail: o.message, reversible: false, restoreNote: "需要的话可重新清理")
        return o
    }
}

struct CleanRecordRow: View {
    let record: CleanRecord
    @ObservedObject var store: CleanStore
    var body: some View {
        HStack(spacing: 8) {
            Text((record.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(CleanLogic.fmtSize(record.size)).font(.system(size: 12)).foregroundColor(DS.text.secondary)
            switch CleanRestore.status(record) {
            case .available:
                Button("恢复") { store.restore(record) }.controlSize(.small).disabled(store.trashing)
                    .accessibilityIdentifier("clean.restore." + record.id.uuidString).accessibilityLabel("恢复 " + (record.path as NSString).lastPathComponent)
            case .restored: Text("已恢复").font(.system(size: 12)).foregroundColor(DS.text.secondary)
            case .trashGone: Text("废纸篓里已不在").font(.system(size: 12)).foregroundColor(DS.text.secondary)
            case .untracked: Text("需手动放回").font(.system(size: 12)).foregroundColor(DS.text.secondary)
            }
        }
    }
}
