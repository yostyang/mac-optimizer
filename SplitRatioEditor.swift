// 2.14 分区比例编辑：图上拖动分隔线、选中分隔线后 ← → 每次 5%、直接输入百分比
// 2.16 N9：上下拆分的栏可以拖动横线、↑ ↓ 每次 5%（⇧ 1%）、输入上方百分比；恢复默认比例；Esc 取消未提交的值
import SwiftUI
import AppKit

struct SplitCustomEditor: View {
    let uuid: String
    let prefs: SplitPrefs
    let changed: () -> Void
    /// 拖动中的比例：松手才保存（保存会刷新整个详情区，拖动中刷新会打断手势）
    @State private var live: [Int]? = nil
    @State private var liveRows: [Int: [Int]] = [:]
    /// Esc 取消当前拖动：松手时不再提交
    @State private var cancelled = false
    @State private var texts: [Int: String] = [:]
    @State private var rowTexts: [Int: String] = [:]
    @State private var inputNote = ""
    @State private var lastFocus: String? = nil
    @FocusState private var focus: String?
    static let hint = "拖动分隔线或输入百分比调整各栏宽度；选中分隔线后用 ← → 每次调 5%（按住 ⇧ 每次 1%，拖动时按住 ⌥ 不吸附）。点每栏旁的图标可以把这一栏上下拆分，拖动横线或用 ↑ ↓ 调上下比例（每区至少 20%）。拖动中按 Esc 取消。"

    var body: some View {
        let cur = prefs.custom(uuid)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { if cur == nil { apply(SplitCustom.seed(from: prefs.weights(uuid))) } }) {
                HStack {
                    SplitPreview(weights: (cur ?? SplitCustom.seed(from: prefs.weights(uuid))).map { CGFloat($0) }, rowPercents: cur == nil ? [] : prefs.rowPercents(uuid)).frame(width: 96, height: 40)
                    Text(cur.map { "自定义 " + SplitCustom.title($0) + (prefs.rows(uuid).contains(2) ? "（含上下拆分）" : "") } ?? "自定义比例"); Spacer()
                    if cur != nil { Image(systemName: "checkmark").foregroundColor(accent) }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("split.custom")
            if prefs.v2Invalid(uuid) {
                StateLine(kind: .unknown, text: "这块屏幕保存的分区数据无法识别，已按旧设置显示", detail: "原数据没有被改动；可点「恢复默认比例」重新开始。", id: "split.custom.invalid")
            }
            // 比例编辑与恢复默认只在自定义布局已启用时出现；查看页面不会自动启用
            if let saved = cur {
                let p = live ?? saved
                let rp = prefs.rowPercents(uuid)
                let shownRows = rp.indices.map { liveRows[$0] ?? rp[$0] }
                SplitRatioCanvas(p: p, rowPercents: shownRows,
                                 onDrag: { i, f, snap in cancelled = false; live = SplitCustom.dragDivider(live ?? saved, i, to: f, snap: snap); inputNote = "" },
                                 onEnd: { if !cancelled, let l = live, l != saved { apply(l) }; live = nil; cancelled = false },
                                 onStep: { i, d, snap in apply(SplitCustom.moveDivider(saved, i, by: d, snap: snap)) },
                                 onRowDrag: { c, f, snap in cancelled = false; liveRows[c] = SplitRows.drag(to: f, snap: snap); inputNote = "" },
                                 onRowEnd: { c in if !cancelled, let r = liveRows[c], r != rp[safe: c] { applyRows(r, column: c) }; liveRows[c] = nil; cancelled = false },
                                 onRowStep: { c, d, snap in if let r = rp[safe: c], r.count == 2 { applyRows(SplitRows.move(r, by: d, snap: snap), column: c) } })
                    .frame(height: 64).accessibilityIdentifier("split.custom.canvas")
                HStack(spacing: 10) {
                    ForEach(Array(p.enumerated()), id: \.offset) { i, v in
                        HStack(spacing: 2) {
                            TextField("", text: Binding(get: { texts[i] ?? "\(v)" }, set: { texts[i] = $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing).monospacedDigit()
                                .focused($focus, equals: "w\(i)").onSubmit { commit(i, saved) }
                                .onExitCommand { texts[i] = nil; inputNote = ""; focus = nil }
                                .accessibilityIdentifier("split.custom.pct.\(i)").accessibilityLabel("第 \(i + 1) 栏宽度百分比")
                            Text("%").font(DS.sub()).foregroundColor(DS.text.secondary)
                            let stacked = prefs.rows(uuid)[safe: i] == 2
                            Button(action: { toggleRows(i) }) { Image(systemName: stacked ? "rectangle.split.1x2.fill" : "rectangle.split.1x2") }
                                .help(stacked ? "取消上下拆分" : "这一栏上下拆分（默认 50% / 50%）").accessibilityIdentifier("split.custom.rows.\(i)")
                                .accessibilityLabel("第 \(i + 1) 栏" + (stacked ? "取消上下拆分" : "上下拆分"))
                        }
                    }
                    Spacer()
                    Button("减一栏") { apply(SplitCustom.removeColumn(saved)) }.disabled(saved.count <= SplitCustom.columns.lowerBound).accessibilityIdentifier("split.custom.remove")
                    Button("加一栏") { apply(SplitCustom.addColumn(saved)) }.disabled(saved.count >= SplitCustom.columns.upperBound).accessibilityIdentifier("split.custom.add")
                }.controlSize(.small)
                if rp.contains(where: { $0.count == 2 }) {
                    HStack(spacing: 12) {
                        Text("上下比例").font(DS.sub()).foregroundColor(DS.text.secondary)
                        ForEach(rp.indices.filter { rp[$0].count == 2 }, id: \.self) { c in
                            HStack(spacing: 2) {
                                Text("第 \(c + 1) 栏上方").font(DS.sub())
                                TextField("", text: Binding(get: { rowTexts[c] ?? "\((liveRows[c] ?? rp[c])[0])" }, set: { rowTexts[c] = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing).monospacedDigit()
                                    .focused($focus, equals: "r\(c)").onSubmit { commitRow(c) }
                                    .onExitCommand { rowTexts[c] = nil; inputNote = ""; focus = nil }
                                    .accessibilityIdentifier("split.custom.rowpct.\(c)").accessibilityLabel("第 \(c + 1) 栏上方区域高度百分比")
                                Text("%").font(DS.sub()).foregroundColor(DS.text.secondary)
                            }
                        }
                        Spacer()
                    }.controlSize(.small)
                }
                HStack(spacing: 8) {
                    if !inputNote.isEmpty {
                        Text(inputNote).font(DS.sub()).foregroundColor(DS.text.warn).accessibilityIdentifier("split.custom.note")
                    }
                    Spacer()
                    Button("恢复默认比例") { reset() }.controlSize(.small)
                        .help("只把这块屏幕恢复为左右两栏 50% / 50%、不上下拆分，仍保持自定义布局；间距和其他屏幕不变，不移动任何窗口")
                        .accessibilityIdentifier("split.custom.reset")
                }
                Text(Self.hint).font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("split.custom.hint")
            }
        }
        // 拖动中 Esc：放弃这次未提交的比例
        .onExitCommand { if live != nil || !liveRows.isEmpty { cancelled = true; live = nil; liveRows = [:]; inputNote = "已取消，比例保持不变" } }
        // 输入框失去焦点也提交（按现有规则校验）
        .onChange(of: focus) { now in
            if let prev = lastFocus, prev != now, let saved = prefs.custom(uuid) {
                if prev.hasPrefix("w"), let i = Int(prev.dropFirst()) { commit(i, saved) }
                if prev.hasPrefix("r"), let c = Int(prev.dropFirst()) { commitRow(c) }
            }
            lastFocus = now
        }
    }
    private func commit(_ i: Int, _ saved: [Int]) {
        guard let raw = texts[i] else { return }
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        texts[i] = nil
        guard let v = Int(s) else { inputNote = "请输入整数百分比，例如 30"; return }
        guard saved.indices.contains(i), v != saved[i] else { return }
        switch SplitCustom.set(saved, column: i, to: v) {
        case .ok(let p): inputNote = ""; apply(p)
        case .rejected(let why): inputNote = why
        }
    }
    private func commitRow(_ c: Int) {
        guard let raw = rowTexts[c] else { return }
        rowTexts[c] = nil
        switch SplitRows.parse(raw) {
        case .ok(let r): inputNote = ""; if r != prefs.rowPercents(uuid)[safe: c] { applyRows(r, column: c) }
        case .rejected(let why): inputNote = why
        }
    }
    private func apply(_ p: [Int]) {
        // setCustom 保留已有各栏的上下比例，新加的栏不拆分
        prefs.setCustom(p, for: uuid)
        if prefs.custom(uuid) != p { inputNote = "保存失败，比例保持为上次成功保存的值" }
        changed()
    }
    private func applyRows(_ r: [Int], column c: Int) {
        if !prefs.setRowPercents(r, column: c, for: uuid) { inputNote = "保存失败，上下比例保持为上次成功保存的值" }
        changed()
    }
    private func toggleRows(_ i: Int) {
        let stacked = prefs.rows(uuid)[safe: i] == 2
        if !prefs.setRowPercents(stacked ? nil : SplitRows.defaultSplit, column: i, for: uuid) { inputNote = "保存失败，设置保持不变" }
        changed()
    }
    private func reset() {
        prefs.resetCustom(uuid); live = nil; liveRows = [:]; texts = [:]; rowTexts = [:]
        inputNote = prefs.custom(uuid) == [50, 50] && prefs.rows(uuid) == [1, 1] ? "" : "恢复默认失败，设置保持不变"
        changed()
    }
}

/// 比例预览图：每栏标出百分比，栏与栏之间是可拖动、可键盘调节的竖线；上下拆分的栏有可拖动的横线
struct SplitRatioCanvas: View {
    let p: [Int]
    let rowPercents: [[Int]]
    let onDrag: (Int, CGFloat, Bool) -> Void
    let onEnd: () -> Void
    let onStep: (Int, Int, Bool) -> Void
    var onRowDrag: (Int, CGFloat, Bool) -> Void = { _, _, _ in }
    var onRowEnd: (Int) -> Void = { _ in }
    var onRowStep: (Int, Int, Bool) -> Void = { _, _, _ in }
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let edges = p.indices.map { i in CGFloat(p[..<i].reduce(0, +)) / 100 * w }
            ZStack(alignment: .topLeading) {
                ForEach(Array(p.enumerated()), id: \.offset) { i, v in
                    let cw = CGFloat(v) / 100 * w
                    let rp = rowPercents[safe: i] ?? []
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent.opacity(0.14))
                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(accent.opacity(0.45), lineWidth: 1)
                        if rp.count == 2 {
                            VStack(spacing: 0) {
                                Text("\(v)% · 上 \(rp[0])%").font(DS.cap(.semibold)).monospacedDigit().frame(height: h * CGFloat(rp[0]) / 100)
                                Text("下 \(rp[1])%").font(DS.cap(.semibold)).monospacedDigit().frame(maxHeight: .infinity)
                            }.frame(height: h).foregroundColor(.primary)
                        } else {
                            Text("\(v)%").font(DS.sub(.semibold)).monospacedDigit().foregroundColor(.primary).frame(height: h)
                        }
                    }
                    .frame(width: max(cw - 4, 1), height: h).offset(x: edges[i] + 2)
                    .accessibilityHidden(true)
                    if rp.count == 2 {
                        SplitRowHandle(column: i, top: rp[0], bottom: rp[1], onStep: onRowStep)
                            .frame(width: max(cw - 12, 1), height: 12)
                            .position(x: edges[i] + cw / 2, y: h * CGFloat(rp[0]) / 100)
                            .gesture(SwiftUI.DragGesture(minimumDistance: 0, coordinateSpace: .named("splitCanvas"))
                                .onChanged { v in onRowDrag(i, min(max(v.location.y / max(h, 1), 0), 1), !NSEvent.modifierFlags.contains(.option)) }
                                .onEnded { _ in onRowEnd(i) })
                    }
                }
                ForEach(0..<max(p.count - 1, 0), id: \.self) { i in
                    SplitDividerHandle(index: i, left: p[i], right: p[i + 1], onStep: onStep)
                        .frame(width: 16, height: h).position(x: edges[i + 1], y: h / 2)
                        .gesture(SwiftUI.DragGesture(minimumDistance: 0, coordinateSpace: .named("splitCanvas"))
                            .onChanged { v in onDrag(i, min(max(v.location.x / max(w, 1), 0), 1), !NSEvent.modifierFlags.contains(.option)) }
                            .onEnded { _ in onEnd() })
                }
            }
        }
        .coordinateSpace(name: "splitCanvas")
        .accessibilityElement(children: .contain)
    }
}

struct SplitDividerHandle: View {
    let index: Int
    let left: Int
    let right: Int
    let onStep: (Int, Int, Bool) -> Void
    @FocusState private var focused: Bool
    @State private var hover = false
    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Capsule().fill(focused ? accent : Color.primary.opacity(hover ? 0.55 : 0.35)).frame(width: focused ? 4 : 3).padding(.vertical, 10)
        }
        .focusable().focused($focused)
        .onTapGesture { focused = true }
        .onMoveCommand { dir in
            let fine = NSEvent.modifierFlags.contains(.shift)
            switch dir {
            case .left: onStep(index, fine ? -1 : -SplitCustom.step, !fine)
            case .right: onStep(index, fine ? 1 : SplitCustom.step, !fine)
            default: break
            }
        }
        .onHover { inside in hover = inside; if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .accessibilityElement()
        .accessibilityLabel("第 \(index + 1)、\(index + 2) 栏之间的分隔线")
        .accessibilityValue("左侧 \(left)%，右侧 \(right)%")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: onStep(index, SplitCustom.step, true)
            case .decrement: onStep(index, -SplitCustom.step, true)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("split.divider.\(index)")
    }
}

/// 2.16：上下拆分栏里的横线；↑ ↓ 每次 5%（⇧ 1%），每区至少 20%
struct SplitRowHandle: View {
    let column: Int
    let top: Int
    let bottom: Int
    let onStep: (Int, Int, Bool) -> Void
    @FocusState private var focused: Bool
    @State private var hover = false
    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Capsule().fill(focused ? accent : Color.primary.opacity(hover ? 0.55 : 0.35)).frame(height: focused ? 4 : 3).padding(.horizontal, 6)
        }
        .focusable().focused($focused)
        .onTapGesture { focused = true }
        .onMoveCommand { dir in
            let fine = NSEvent.modifierFlags.contains(.shift)
            switch dir {
            case .up: onStep(column, fine ? -1 : -SplitRows.step, !fine)
            case .down: onStep(column, fine ? 1 : SplitRows.step, !fine)
            default: break
            }
        }
        .onHover { inside in hover = inside; if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .accessibilityElement()
        .accessibilityLabel("第 \(column + 1) 栏上下两区之间的分隔线")
        .accessibilityValue("上方 \(top)%，下方 \(bottom)%")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: onStep(column, SplitRows.step, true)
            case .decrement: onStep(column, -SplitRows.step, true)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("split.rowdivider.\(column)")
    }
}
