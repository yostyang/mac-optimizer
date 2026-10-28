import SwiftUI
import AppKit

/// 小号选择块（分辨率、刷新率、输入源共用）
struct ChoiceChip: View {
    let text: String; let on: Bool; var sub: String = ""; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(text).font(.system(size: 11, weight: on ? .semibold : .regular)).monospacedDigit().lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 9)).opacity(0.7) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5).frame(minWidth: 64)
            .foregroundColor(on ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? AnyShapeStyle(LinearGradient(colors: [accent2, accent], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.primary.opacity(0.06))))
        }.buttonStyle(.plain)
    }
}
struct FlowRow<Content: View>: View {
    let spacing: CGFloat; @ViewBuilder let content: Content
    var body: some View {
        if #available(macOS 13.0, *) { FlowLayout(spacing: spacing) { content } } else { HStack(spacing: spacing) { content } }
    }
}
@available(macOS 13.0, *)
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400; var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews { let z = s.sizeThatFits(.unspecified); if x + z.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }; x += z.width + spacing; row = max(row, z.height) }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews { let z = s.sizeThatFits(.unspecified); if x + z.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z)); x += z.width + spacing; row = max(row, z.height) }
    }
}

func fmtDuration(_ s: Double) -> String { let m = Int(s / 60); return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟" }

struct DisplayPage: View {
    @ObservedObject var dm = DisplayManager.shared
    @ObservedObject var st = ScreenTime.shared
    @State private var sel: CGDirectDisplayID = 0
    @State private var hidpi = true
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("显示器").font(.system(size: 24, weight: .bold))
                        Text("分辨率、硬件亮度、护眼色温和亮屏时间").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if dm.displays.count > 1 {
                        Picker("", selection: $sel) { ForEach(dm.displays) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 200)
                    }
                    Button { dm.refresh(); dm.probeDDC() } label: { Label(dm.probing ? "读取中…" : "刷新", systemImage: "arrow.clockwise") }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("disp.refresh")
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) { modeCard; ddcCard }.frame(maxWidth: .infinity)
                    VStack(spacing: 10) { eyeCard; usageCard }.frame(maxWidth: .infinity)
                }
            }.padding(28)
        }
        .onAppear {
            if dm.displays.isEmpty || !dm.offline { dm.refresh() }
            if sel == 0 || !dm.displays.contains(where: { $0.id == sel }) { sel = (dm.displays.first { !$0.builtin } ?? dm.displays.first)?.id ?? 0 }
            hidpi = cur?.current.hidpi ?? true
            if !dm.offline && dm.ddc.isEmpty { dm.probeDDC() }
        }
    }
    var cur: DisplayInfo? { dm.displays.first { $0.id == sel } ?? dm.displays.first }

    var modeCard: some View {
        Card(title: "分辨率与刷新率", icon: "display") {
            if let d = cur {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 15, weight: .semibold))
                        Text("\(d.current.label) · \(d.current.refreshLabel)" + (d.current.hidpi ? " · HiDPI" : "") + "  （实际像素 \(d.current.pixelWidth)×\(d.current.pixelHeight)）").font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if d.hasHiDPIChoice { Toggle("HiDPI", isOn: $hidpi).toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("disp.hidpi") }
                }
                if let p = dm.pending, p.id == d.id {
                    HStack(spacing: 8) {
                        Image(systemName: "timer").foregroundColor(.orange)
                        Text("显示正常吗？\(Int(DisplayManager.confirmSeconds)) 秒内不确认会自动还原").font(.system(size: 11))
                        Spacer()
                        Button("还原") { dm.revert() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("disp.revert")
                        Button("保留") { dm.keep() }.buttonStyle(PillButton()).accessibilityIdentifier("disp.keep")
                    }.padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
                Text("分辨率").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(d.resolutions(hidpi: hidpi), id: \.self) { m in
                        ChoiceChip(text: m.label, on: m.label == d.current.label && m.hidpi == d.current.hidpi) {
                            let rate = d.refreshRates(for: m).first { abs($0 - d.current.refresh.rounded()) < 1 } ?? d.refreshRates(for: m).first ?? m.refresh
                            let target = d.modes.first { $0.width == m.width && $0.height == m.height && $0.hidpi == m.hidpi && abs($0.refresh.rounded() - rate) < 1 } ?? m
                            dm.switchMode(d.id, to: target)
                        }
                    }
                }
                let rates = d.refreshRates(for: d.current)
                if rates.count > 1 {
                    Text("刷新率").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        ForEach(rates, id: \.self) { r in
                            ChoiceChip(text: "\(Int(r)) Hz", on: abs(d.current.refresh.rounded() - r) < 1) {
                                if let t = d.modes.first(where: { $0.width == d.current.width && $0.height == d.current.height && $0.hidpi == d.current.hidpi && abs($0.refresh.rounded() - r) < 1 }) { dm.switchMode(d.id, to: t) }
                            }
                        }
                    }
                }
            } else { Text("没有检测到显示器").foregroundColor(.secondary) }
        }
    }

    func slider(_ title: String, _ icon: String, value: Int?, max mx: Int, id: String, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundColor(accent)
            Text(title).font(.system(size: 12)).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { Double(value ?? 0) }, set: { set(Int($0.rounded())) }), in: 0...Double(max(1, mx))).controlSize(.small).accessibilityIdentifier(id)
            Text("\(value ?? 0)").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }
    var ddcCard: some View {
        Card(title: "硬件调节（DDC/CI）", icon: "slider.horizontal.3") {
            if let d = cur, d.builtin {
                Text("内建屏幕请用键盘亮度键调节；硬件调节只适用于外接显示器。").font(.system(size: 11)).foregroundColor(.secondary)
            } else if let d = cur, let s = dm.ddc[d.id], s.available {
                if s.brightness != nil { slider("亮度", "sun.max", value: s.brightness, max: s.brightnessMax, id: "ddc.brightness") { dm.setDDC(d.id, .brightness, $0) } }
                if s.contrast != nil { slider("对比度", "circle.lefthalf.filled", value: s.contrast, max: s.contrastMax, id: "ddc.contrast") { dm.setDDC(d.id, .contrast, $0) } }
                if s.volume != nil { slider("音量", "speaker.wave.2", value: s.volume, max: s.volumeMax, id: "ddc.volume") { dm.setDDC(d.id, .volume, $0) } }
                if s.caps.inputs.count > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.connected.to.line.below").frame(width: 16).foregroundColor(accent)
                        Text("输入源").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                        ForEach(s.caps.inputs, id: \.self) { v in
                            ChoiceChip(text: DDCCaps.inputName(v), on: s.input == v) { if s.input != v { confirmInput(d.id, v) } }
                        }
                    }
                    Text("切到其他输入源后，这台 Mac 的画面会从该显示器上消失，需要用显示器按键切回。").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let miss = [s.volume == nil ? "音量" : nil, s.caps.inputs.count > 1 ? nil : "输入源"].compactMap { $0 }
                if !miss.isEmpty { Text("这台显示器不支持通过 DDC 调" + miss.joined(separator: "、") + "，已隐藏。").font(.system(size: 10)).foregroundColor(.secondary) }
            } else if dm.probing {
                HStack { ProgressView().controlSize(.small); Text("正在读取显示器…").font(.system(size: 11)).foregroundColor(.secondary) }
            } else {
                Text("这台显示器没有响应 DDC/CI。可以在显示器菜单里打开 DDC/CI 后点「刷新」，或使用右侧的软件调光。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func confirmInput(_ id: CGDirectDisplayID, _ v: UInt8) {
        let a = NSAlert(); a.messageText = "切换到 \(DDCCaps.inputName(v))？"; a.informativeText = "画面会切到显示器的另一路输入，这台 Mac 的画面将不再显示在该显示器上。"
        a.addButton(withTitle: "切换"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { dm.setDDC(id, .input, Int(v)) }
    }

    var eyeCard: some View {
        Card(title: "护眼与场景", icon: "eye") {
            HStack(spacing: 8) {
                ForEach(DScene.all) { s in
                    Button { dm.apply(scene: s) } label: {
                        VStack(spacing: 4) { Image(systemName: s.icon).font(.system(size: 15)); Text(s.name).font(.system(size: 11)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundColor(dm.settings.scene == s.id ? .white : .primary)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(dm.settings.scene == s.id ? AnyShapeStyle(LinearGradient(colors: [accent2, accent], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.primary.opacity(0.06))))
                    }.buttonStyle(.plain).accessibilityIdentifier("scene.\(s.id)")
                }
            }
            if !dm.conflict.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("检测到 \(dm.conflict) 正在运行，它也会调整屏幕色彩。为避免互相覆盖，软件调光默认不开；场景只调硬件亮度。").font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("软件调光与色温（关闭即恢复系统原色）", isOn: Binding(get: { dm.settings.gammaOn }, set: { dm.setGamma(on: $0) })).toggleStyle(.switch).controlSize(.small).font(.system(size: 11)).accessibilityIdentifier("disp.gamma")
            HStack(spacing: 8) {
                Image(systemName: "sun.min").frame(width: 16).foregroundColor(accent); Text("调暗").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                Slider(value: Binding(get: { dm.settings.dim }, set: { dm.setDim($0) }), in: 0.3...1).controlSize(.small).disabled(!dm.settings.gammaOn)
                Text("\(Int(dm.settings.dim * 100))%").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Image(systemName: "thermometer.sun").frame(width: 16).foregroundColor(.orange); Text("色温").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                Slider(value: Binding(get: { dm.settings.kelvin }, set: { dm.setKelvin($0) }), in: 2700...6500).controlSize(.small).disabled(!dm.settings.gammaOn)
                Text("\(Int(dm.settings.kelvin))K").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Toggle("按时间自动切换", isOn: Binding(get: { dm.settings.autoSwitch }, set: { dm.settings.autoSwitch = $0; dm.scheduleAuto() })).toggleStyle(.switch).controlSize(.small).font(.system(size: 11)).accessibilityIdentifier("disp.auto")
                Spacer()
                Text("日间 \(hm(dm.settings.dayStart))  ·  夜间 \(hm(dm.settings.nightStart))").font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
                Stepper("", onIncrement: { dm.settings.nightStart = (dm.settings.nightStart + 30) % 1440; dm.scheduleAuto() }, onDecrement: { dm.settings.nightStart = (dm.settings.nightStart + 1410) % 1440; dm.scheduleAuto() }).labelsHidden().controlSize(.small).help("调整夜间开始时间")
            }
        }
    }
    func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    var usageCard: some View {
        let w = st.week; let mx = max(3600, w.map(\.1).max() ?? 1)
        return Card(title: "亮屏时间", icon: "hourglass") {
            HStack(alignment: .firstTextBaseline) {
                Text(fmtDuration(st.today)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text("今天").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text("7 天平均 " + fmtDuration(w.map(\.1).reduce(0, +) / 7)).font(.system(size: 11)).foregroundColor(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(w.enumerated()), id: \.offset) { i, e in
                    VStack(spacing: 4) {
                        Text(e.1 >= 3600 ? String(format: "%.1fh", e.1 / 3600) : "\(Int(e.1 / 60))m").font(.system(size: 9)).foregroundColor(.secondary).monospacedDigit()
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(i == 6 ? AnyShapeStyle(LinearGradient(colors: [accent2, accent], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(accent.opacity(0.35)))
                            .frame(height: max(3, 64 * CGFloat(e.1 / mx)))
                        Text(e.0).font(.system(size: 10)).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 96, alignment: .bottom)
            Text("屏幕亮着且已解锁的时间；按屏幕睡眠/锁屏事件记账，不轮询。").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}
