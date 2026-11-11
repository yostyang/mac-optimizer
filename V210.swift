// 2.10：自定义分区比例、拖动到分区的开关、清理记录恢复
import SwiftUI
import AppKit

// MARK: - 自定义比例
enum SplitCustom {
    static let columns = 2...4
    static let weight = 1...9
    static func valid(_ w: [Int]) -> Bool { columns.contains(w.count) && w.allSatisfy { weight.contains($0) } }
    static func title(_ w: [Int]) -> String { w.map(String.init).joined(separator: " : ") }
    /// 进入自定义时的起点：沿用当前模板的比例，没有就从 1:1 开始
    static func seed(from weights: [CGFloat]?) -> [Int] {
        let w = (weights ?? [1, 1]).map { Int($0.rounded()) }
        return valid(w) ? w : [1, 1]
    }
    static func adjust(_ w: [Int], column i: Int, by d: Int) -> [Int] {
        guard w.indices.contains(i) else { return w }
        var out = w; out[i] = min(max(out[i] + d, weight.lowerBound), weight.upperBound); return out
    }
    static func addColumn(_ w: [Int]) -> [Int] { w.count < columns.upperBound ? w + [1] : w }
    static func removeColumn(_ w: [Int]) -> [Int] { w.count > columns.lowerBound ? Array(w.dropLast()) : w }
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

struct SplitCustomEditor: View {
    let uuid: String
    let prefs: SplitPrefs
    let changed: () -> Void
    var body: some View {
        let cur = prefs.custom(uuid)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { if cur == nil { apply(SplitCustom.seed(from: prefs.weights(uuid))) } }) {
                HStack {
                    SplitPreview(weights: (cur ?? SplitCustom.seed(from: prefs.weights(uuid))).map { CGFloat($0) }, rows: cur == nil ? [] : prefs.rows(uuid)).frame(width: 96, height: 40)
                    Text(cur.map { "自定义 " + SplitCustom.title($0) + (prefs.rows(uuid).contains(2) ? "（含上下平分）" : "") } ?? "自定义比例"); Spacer()
                    if cur != nil { Image(systemName: "checkmark").foregroundColor(accent) }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("split.custom")
            if let w = cur {
                HStack(spacing: 10) {
                    ForEach(Array(w.enumerated()), id: \.offset) { i, v in
                        HStack(spacing: 2) {
                            Button(action: { apply(SplitCustom.adjust(w, column: i, by: -1)) }) { Image(systemName: "minus") }
                                .disabled(v <= SplitCustom.weight.lowerBound).accessibilityIdentifier("split.custom.minus.\(i)").accessibilityLabel("第 \(i + 1) 栏变窄")
                            Text("\(v)").font(DS.sub(.semibold)).monospacedDigit().frame(minWidth: 14)
                            Button(action: { apply(SplitCustom.adjust(w, column: i, by: 1)) }) { Image(systemName: "plus") }
                                .disabled(v >= SplitCustom.weight.upperBound).accessibilityIdentifier("split.custom.plus.\(i)").accessibilityLabel("第 \(i + 1) 栏变宽")
                            let stacked = prefs.rows(uuid)[safe: i] == 2
                            Button(action: { toggleRows(i) }) { Image(systemName: stacked ? "rectangle.split.1x2.fill" : "rectangle.split.1x2") }
                                .help(stacked ? "取消上下平分" : "这一栏上下平分").accessibilityIdentifier("split.custom.rows.\(i)")
                                .accessibilityLabel("第 \(i + 1) 栏" + (stacked ? "取消上下平分" : "上下平分"))
                        }
                    }
                    Spacer()
                    Button("减一栏") { apply(SplitCustom.removeColumn(w)) }.disabled(w.count <= SplitCustom.columns.lowerBound).accessibilityIdentifier("split.custom.remove")
                    Button("加一栏") { apply(SplitCustom.addColumn(w)) }.disabled(w.count >= SplitCustom.columns.upperBound).accessibilityIdentifier("split.custom.add")
                }.controlSize(.small)
                Text("数字是各栏的宽度比例，可设 2 到 4 栏；点每栏右边的图标，可以把这一栏再上下平分。").font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func apply(_ w: [Int]) {
        // 加减栏时保留已有各栏的上下平分设置
        let old = prefs.custom(uuid) == nil ? [] : prefs.rows(uuid)
        prefs.setCustom(w, for: uuid)
        prefs.setRows(w.indices.map { old.indices.contains($0) ? old[$0] : 1 }, for: uuid)
        changed()
    }
    private func toggleRows(_ i: Int) {
        var r = prefs.rows(uuid); guard r.indices.contains(i) else { return }
        r[i] = r[i] == 2 ? 1 : 2; prefs.setRows(r, for: uuid); changed()
    }
}
private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

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
