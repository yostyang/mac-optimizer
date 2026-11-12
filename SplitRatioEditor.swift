// 2.14 分区比例编辑：图上拖动分隔线、选中分隔线后 ← → 每次 5%、直接输入百分比
import SwiftUI
import AppKit

struct SplitCustomEditor: View {
    let uuid: String
    let prefs: SplitPrefs
    let changed: () -> Void
    /// 拖动中的比例：松手才保存（保存会刷新整个详情区，拖动中刷新会打断手势）
    @State private var live: [Int]? = nil
    @State private var texts: [Int: String] = [:]
    @State private var inputNote = ""
    @State private var lastFocus: Int? = nil
    @FocusState private var focus: Int?
    static let hint = "拖动分隔线或输入百分比调整各栏宽度；选中分隔线后用 ← → 每次调 5%（按住 ⇧ 每次 1%，拖动时按住 ⌥ 不吸附）。点每栏旁的图标可以把这一栏上下平分。"

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
            if let saved = cur {
                let p = live ?? saved
                SplitRatioCanvas(p: p, rows: prefs.rows(uuid),
                                 onDrag: { i, f, snap in live = SplitCustom.dragDivider(live ?? saved, i, to: f, snap: snap); inputNote = "" },
                                 onEnd: { if let l = live, l != saved { apply(l) }; live = nil },
                                 onStep: { i, d, snap in apply(SplitCustom.moveDivider(saved, i, by: d, snap: snap)) })
                    .frame(height: 64).accessibilityIdentifier("split.custom.canvas")
                HStack(spacing: 10) {
                    ForEach(Array(p.enumerated()), id: \.offset) { i, v in
                        HStack(spacing: 2) {
                            TextField("", text: Binding(get: { texts[i] ?? "\(v)" }, set: { texts[i] = $0 }))
                                .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing).monospacedDigit()
                                .focused($focus, equals: i).onSubmit { commit(i, saved) }
                                .accessibilityIdentifier("split.custom.pct.\(i)").accessibilityLabel("第 \(i + 1) 栏宽度百分比")
                            Text("%").font(DS.sub()).foregroundColor(DS.text.secondary)
                            let stacked = prefs.rows(uuid)[safe: i] == 2
                            Button(action: { toggleRows(i) }) { Image(systemName: stacked ? "rectangle.split.1x2.fill" : "rectangle.split.1x2") }
                                .help(stacked ? "取消上下平分" : "这一栏上下平分").accessibilityIdentifier("split.custom.rows.\(i)")
                                .accessibilityLabel("第 \(i + 1) 栏" + (stacked ? "取消上下平分" : "上下平分"))
                        }
                    }
                    Spacer()
                    Button("减一栏") { apply(SplitCustom.removeColumn(saved)) }.disabled(saved.count <= SplitCustom.columns.lowerBound).accessibilityIdentifier("split.custom.remove")
                    Button("加一栏") { apply(SplitCustom.addColumn(saved)) }.disabled(saved.count >= SplitCustom.columns.upperBound).accessibilityIdentifier("split.custom.add")
                }.controlSize(.small)
                if !inputNote.isEmpty {
                    Text(inputNote).font(DS.sub()).foregroundColor(DS.text.warn).accessibilityIdentifier("split.custom.note")
                }
                Text(Self.hint).font(DS.sub()).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("split.custom.hint")
            }
        }
        // 输入框失去焦点也提交
        .onChange(of: focus) { now in
            if let prev = lastFocus, prev != now, let saved = prefs.custom(uuid) { commit(prev, saved) }
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
    private func apply(_ p: [Int]) {
        // 加减栏时保留已有各栏的上下平分设置
        let old = prefs.custom(uuid) == nil ? [] : prefs.rows(uuid)
        prefs.setCustom(p, for: uuid)
        prefs.setRows(p.indices.map { old.indices.contains($0) ? old[$0] : 1 }, for: uuid)
        changed()
    }
    private func toggleRows(_ i: Int) {
        var r = prefs.rows(uuid); guard r.indices.contains(i) else { return }
        r[i] = r[i] == 2 ? 1 : 2; prefs.setRows(r, for: uuid); changed()
    }
}

/// 比例预览图：每栏标出百分比，栏与栏之间是可拖动、可键盘调节的分隔线
struct SplitRatioCanvas: View {
    let p: [Int]
    let rows: [Int]
    let onDrag: (Int, CGFloat, Bool) -> Void
    let onEnd: () -> Void
    let onStep: (Int, Int, Bool) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let edges = p.indices.map { i in CGFloat(p[..<i].reduce(0, +)) / 100 * w }
            ZStack(alignment: .topLeading) {
                ForEach(Array(p.enumerated()), id: \.offset) { i, v in
                    let cw = CGFloat(v) / 100 * w
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent.opacity(0.14))
                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(accent.opacity(0.45), lineWidth: 1)
                        if rows[safe: i] == 2 { Rectangle().fill(accent.opacity(0.45)).frame(height: 1) }
                        Text("\(v)%").font(DS.sub(.semibold)).monospacedDigit().foregroundColor(.primary)
                    }
                    .frame(width: max(cw - 4, 1), height: h).offset(x: edges[i] + 2)
                    .accessibilityHidden(true)
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
