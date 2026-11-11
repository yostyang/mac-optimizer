// v2.5 设计基础：中性灰阶 + 品牌紫（取自 App 图标那道紫→蓝弧线的紫）
// 只借鉴 Raycast 的交互模式（列表、⌘K、快捷键提示），不使用它的标志、图标与配色。
import SwiftUI
import AppKit

// MARK: - 令牌
/// DS.text 里同名的 good/warn/bad 会遮住全局状态色，这里留一份别名供 tone() 比较
private let statusGood = good, statusWarn = warn, statusBad = bad

enum DS {
    // 表面：中性灰阶。浅色偏白，深色接近图标的深蓝黑，不再大面积铺紫。
    static let window = dyn(NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1),
                            NSColor(srgbRed: 0.086, green: 0.086, blue: 0.165, alpha: 1))   // #F2F2F5 / #16162A
    static let card = dyn(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                          NSColor(srgbRed: 0.067, green: 0.071, blue: 0.118, alpha: 1))      // #FFFFFF / #11121E
    static let raised = dyn(NSColor(srgbRed: 0.980, green: 0.980, blue: 0.988, alpha: 1),
                            NSColor(srgbRed: 0.149, green: 0.149, blue: 0.243, alpha: 1))    // #FAFAFC / #26263E
    static let sidebar = dyn(NSColor(srgbRed: 0.965, green: 0.965, blue: 0.976, alpha: 1),
                             NSColor(srgbRed: 0.075, green: 0.075, blue: 0.149, alpha: 1))   // #F6F6F9 / #131326
    // 描边：卡片用 1px 细线，不再用阴影
    static let border = dyn(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
    static let borderStrong = dyn(NSColor.black.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0.16))
    static let separator = dyn(NSColor.black.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0.07))
    static let hover = dyn(NSColor.black.withAlphaComponent(0.04), NSColor.white.withAlphaComponent(0.05))
    static let press = dyn(NSColor.black.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0.08))

    // 圆角只保留 3 种
    enum r { static let card: CGFloat = 12; static let control: CGFloat = 6; static let pill: CGFloat = 999 }
    static let cardPadding: CGFloat = 16
    static let cardGap: CGFloat = 12
    /// 菜单栏面板里的指标卡、电池宽卡和主窗口紧凑 Tile 的内边距（更紧凑的一档）
    static let tilePadding: CGFloat = 10
    /// 带标题的 `Card`（电池、显示器、网络等详情页）。2.12 仍为 12：改成 16 时电池页在最小窗口（1080×720）超出 28 pt，
    /// 违反「不滚动」测试；2.13 把规则改成「摘要不滚、详情局部滚动」后再统一到 cardPadding
    static let titledCardPadding: CGFloat = 16

    // 2.12 文字承载色：只给文字用，和品牌色、状态图形色、指标色分开。
    // 图标、圆环、曲线、进度条继续用 accent / good / warn / bad；小字一律用这里的令牌。
    // 取值按 WCAG sRGB 相对亮度计算，浅深两套在 window / card / raised / sidebar 上都 ≥ 4.5:1（见 V212Tests）。
    enum text {
        /// 次级文字：说明、单位、列头、角标。浅色不再用半透明黑（约 3.9:1），改为不透明 #62626E
        static let secondary = dyn(NSColor(srgbRed: 0x62 / 255.0, green: 0x62 / 255.0, blue: 0x6E / 255.0, alpha: 1),
                                   NSColor(srgbRed: 0xA1 / 255.0, green: 0xA1 / 255.0, blue: 0xB0 / 255.0, alpha: 1))   // #62626E / #A1A1B0
        /// 正常 / 完成的文字（浅色加深；深色沿用 good）
        static let good = dyn(NSColor(srgbRed: 0x08 / 255.0, green: 0x74 / 255.0, blue: 0x4F / 255.0, alpha: 1),
                              NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1))                              // #08744F / #34D399
        /// 注意的文字
        static let warn = dyn(NSColor(srgbRed: 0x8B / 255.0, green: 0x51 / 255.0, blue: 0x00 / 255.0, alpha: 1),
                              NSColor(srgbRed: 1.0, green: 0.702, blue: 0.251, alpha: 1))                                // #8B5100 / #FFB340
        /// 危险 / 失败的文字
        static let bad = dyn(NSColor(srgbRed: 0xB4 / 255.0, green: 0x23 / 255.0, blue: 0x18 / 255.0, alpha: 1),
                             NSColor(srgbRed: 1.0, green: 0.420, blue: 0.420, alpha: 1))                                 // #B42318 / #FF6B6B
        /// 选中行（selectionFill 上）的主字与副字
        static let onSelection = Color.white
        static let onSelectionSecondary = Color(nsColor: NSColor(srgbRed: 0xEE / 255.0, green: 0xEC / 255.0, blue: 0xFB / 255.0, alpha: 1))   // #EEECFB
        /// 把状态图形色换成对应的文字色；其他颜色原样返回（指标色本身已按文字验收）
        static func tone(_ c: Color) -> Color {
            if c == statusGood { return good }
            if c == statusWarn { return warn }
            if c == statusBad { return bad }
            if c == .secondary { return secondary }
            return c
        }
    }
    /// 承载白字的填充：列表选中行、操作面板选中项、主按钮。比品牌紫深一档，白字 6.44:1（品牌紫 accent 只做图形与焦点）
    static let selectionFill = Color(nsColor: NSColor(srgbRed: 0x58 / 255.0, green: 0x46 / 255.0, blue: 0xD6 / 255.0, alpha: 1))   // #5846D6

    // 字号（2.13）：标题 17 / 正文 13 / 说明 12；10–11 pt 只用于单位和时间，需在行尾注明（fontlint.sh 检查）
    static let fontSizes: [CGFloat] = [30, 22, 17, 13, 12.5, 12, 12, 12]
    static func title(_ w: Font.Weight = .semibold) -> Font { .system(size: 17, weight: w) }
    static func body(_ w: Font.Weight = .regular) -> Font { .system(size: 13, weight: w) }
    static func sub(_ w: Font.Weight = .regular) -> Font { .system(size: 12, weight: w) }
    static func cap(_ w: Font.Weight = .medium) -> Font { .system(size: 12, weight: w) }
    /// 数字：等宽，避免刷新时跳动
    static func num(_ size: CGFloat = 13, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w, design: .rounded).monospacedDigit() }
    static func hero(compact: Bool = false) -> Font { num(compact ? 22 : 30, .semibold) }
    static func unit() -> Font { .system(size: 13, weight: .medium) }
    static func label() -> Font { .system(size: 12.5, weight: .semibold) }
    static func eyebrow() -> Font { .system(size: 12, weight: .semibold) }

    enum metric {
        static let cpu = dyn(NSColor(srgbRed: 0.067, green: 0.475, blue: 0.412, alpha: 1), NSColor(srgbRed: 0.420, green: 0.792, blue: 0.714, alpha: 1))
        static let gpu = dyn(NSColor(srgbRed: 0.322, green: 0.345, blue: 0.722, alpha: 1), NSColor(srgbRed: 0.635, green: 0.647, blue: 0.949, alpha: 1))
        static let memory = dyn(NSColor(srgbRed: 0.659, green: 0.259, blue: 0.471, alpha: 1), NSColor(srgbRed: 0.878, green: 0.584, blue: 0.745, alpha: 1))
        static let disk = dyn(NSColor(srgbRed: 0.129, green: 0.435, blue: 0.643, alpha: 1), NSColor(srgbRed: 0.478, green: 0.729, blue: 0.941, alpha: 1))
        static let network = dyn(NSColor(srgbRed: 0.067, green: 0.439, blue: 0.529, alpha: 1), NSColor(srgbRed: 0.396, green: 0.784, blue: 0.871, alpha: 1))
        static let battery = dyn(NSColor(srgbRed: 0.325, green: 0.455, blue: 0.149, alpha: 1), NSColor(srgbRed: 0.702, green: 0.839, blue: 0.490, alpha: 1))
        static let fan = dyn(NSColor(srgbRed: 0.345, green: 0.396, blue: 0.475, alpha: 1), NSColor(srgbRed: 0.655, green: 0.694, blue: 0.765, alpha: 1))
    }

    static let motionFast: Double = 0.12
    static let motionPanel: Double = 0.22
}

struct MetricStat: Equatable {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

@MainActor struct Unavailable: View {
    var reason: String
    var body: some View {
        Text("—").foregroundColor(DS.text.secondary)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.clear).frame(height: 1)
                    .overlay(Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 14, y: 0)) }
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            }
            .help(reason).accessibilityLabel("暂不可用，" + reason)
    }
}

/// 三层指标：标签、主值与可视化、二级读数。数据来自调用方，不自建采样器。
@MainActor struct MetricTile: View {
    let title: String
    let symbol: String
    let tint: Color
    var value: String?
    var unit = ""
    var note = ""
    var series: [Double] = []
    var maxValue: Double? = nil
    var fraction: Double? = nil
    var stats: [MetricStat] = []
    var unavailableReason = "当前系统没有提供此读数"
    var valueColor: Color = .primary
    var textValue = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(DS.label()).accessibilityHidden(true)
                Text(title).font(DS.label())
                Spacer(minLength: 2)
                if !note.isEmpty { Text(note).font(DS.cap()).foregroundColor(DS.text.secondary).lineLimit(1).help(note) }
            }.foregroundColor(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let value {
                    Text(value).font(textValue ? DS.title() : DS.hero(compact: compact))
                        .foregroundColor(valueColor).lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Unavailable(reason: unavailableReason).font(DS.hero(compact: compact))
                }
                if !unit.isEmpty { Text(unit).font(DS.unit()).foregroundColor(DS.text.secondary) }
                Spacer(minLength: 0)
            }
            if !compact {
                Group {
                    if !series.isEmpty {
                        Spark(values: series, color: tint, maxValue: maxValue)
                    } else if let fraction {
                        Bar(frac: fraction, color: tint, height: 4).frame(maxHeight: .infinity)
                    } else {
                        Color.clear
                    }
                }.frame(height: 22)
                    .padding(.horizontal, series.isEmpty ? 0 : -DS.cardPadding)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 3) {
                ForEach(Array(stats.prefix(compact ? 1 : 2).enumerated()), id: \.offset) { _, stat in
                    HStack(spacing: 6) {
                        Text(stat.label).foregroundColor(DS.text.secondary)
                        Spacer(minLength: 2)
                        Text(stat.value).monospacedDigit().foregroundColor(.primary)
                    }.font(DS.cap()).lineLimit(1).minimumScaleFactor(0.8).help(stat.label + "：" + stat.value)
                }
            }
        }
        .padding(DS.cardPadding)
        .frame(maxWidth: .infinity, minHeight: compact ? 98 : 154, maxHeight: compact ? 98 : 154, alignment: .topLeading)
        .card()
        .clipShape(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title, value.map { $0 + unit } ?? "暂不可用：" + unavailableReason, note]
            + stats.map { $0.label + "：" + $0.value }).filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

@MainActor struct SubStats: View {
    let items: [MetricStat]
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(DS.separator).frame(width: 1, height: 28) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label).font(DS.eyebrow()).tracking(0.3).foregroundColor(DS.text.secondary)
                    Text(item.value).font(DS.num()).lineLimit(1).minimumScaleFactor(0.8)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            }
        }
    }
}

@MainActor struct KPIStrip: View {
    let items: [MetricStat]
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(DS.separator).frame(width: 1, height: 29) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(DS.eyebrow()).tracking(0.3).foregroundColor(DS.text.secondary)
                    Text(item.value).font(DS.body(.medium)).lineLimit(1).minimumScaleFactor(0.75).help(item.value)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("metric.kpis")
    }
}

@MainActor struct StatusPill: View {
    let title: String
    var tint: Color = accent
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(title).font(DS.cap(.medium)).lineLimit(1)
        }.padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
            .accessibilityElement(children: .combine)
    }
}

struct BarListItem {
    let name: String
    let value: String
    let fraction: Double
}

@MainActor struct BarList: View {
    let items: [BarListItem]
    var tint: Color = DS.metric.network
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    HStack {
                        Text(item.name).font(DS.sub()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(item.value).font(DS.num(12)).lineLimit(1)
                    }
                    Bar(frac: item.fraction, color: tint, height: 3).accessibilityHidden(true)
                }.accessibilityElement(children: .ignore).accessibilityLabel(item.name + "，" + item.value)
            }
        }
    }
}

@MainActor struct InlineSegment<Value: Hashable>: View {
    let items: [(String, Value)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { selection = item.1 } label: {
                    Text(item.0).font(DS.cap(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundColor(selection == item.1 ? .primary : DS.text.secondary)
                        .background(RoundedRectangle(cornerRadius: DS.r.control).fill(selection == item.1 ? DS.card : .clear))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == item.1 ? .isSelected : [])
            }
        }.padding(2).background(RoundedRectangle(cornerRadius: DS.r.control).fill(Color.primary.opacity(0.04)))
    }
}

@MainActor struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(DS.cap(.regular)).foregroundColor(DS.text.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 毛玻璃
/// 主窗口/侧栏/面板的毛玻璃底。离屏截图时 NSVisualEffectView 会拍成空白，
/// 测试模式退回实色，保证截图基准与对比度检查仍然有效。
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending
        v.state = .followsWindowActiveState; v.isEmphasized = false
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blending
    }
}

struct Vibrancy: View {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var solid: Color = DS.window
    var body: some View {
        if MOTests.active { solid } else { VisualEffect(material: material) }
    }
}

// MARK: - 图标：彩色小方块 + 白色 SF Symbol
struct IconBadge: View {
    let symbol: String
    var tint: Color = accent
    var size: CGFloat = 22
    var selected = false
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(selected ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(tint))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white))
            .accessibilityHidden(true)
    }
}

/// 有 App 图标就用图标，没有就用彩色小方块
struct RowIcon: View {
    let icon: NSImage?; let symbol: String; var tint: Color = accent; var size: CGFloat = 22; var selected = false
    var body: some View {
        if let i = icon {
            Image(nsImage: i).resizable().frame(width: size, height: size)
        } else {
            IconBadge(symbol: symbol, tint: tint, size: size, selected: selected)
        }
    }
}

// MARK: - 快捷键提示
struct Kbd: View {
    let text: String
    var on: Bool = false
    var body: some View {
        Text(text)
            .font(DS.cap(.medium))
            .foregroundColor(on ? DS.text.onSelectionSecondary : DS.text.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                .fill(on ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                .strokeBorder(on ? Color.white.opacity(0.16) : DS.border, lineWidth: 1))
    }
}

// MARK: - 列表行
/// Raycast 式列表行：44pt 高、左侧小方块图标、右侧快捷键/数值；选中时整行品牌紫 + 白字
struct ListRow<Trailing: View>: View {
    let icon: NSImage?
    let symbol: String
    var tint: Color = accent
    let title: String
    var subtitle: String = ""
    var selected = false
    var compact = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(icon: icon, symbol: symbol, tint: tint, size: compact ? 18 : 22, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.body(selected ? .medium : .regular))
                    .foregroundColor(selected ? DS.text.onSelection : .primary).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(DS.sub())
                        .foregroundColor(selected ? DS.text.onSelectionSecondary : DS.text.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 32 : 44)
        .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
            .fill(selected ? AnyShapeStyle(DS.selectionFill) : (hovering ? AnyShapeStyle(DS.hover) : AnyShapeStyle(Color.clear))))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
    }
}

extension ListRow where Trailing == EmptyView {
    init(icon: NSImage?, symbol: String, tint: Color = accent, title: String, subtitle: String = "",
         selected: Bool = false, compact: Bool = false, action: (() -> Void)? = nil) {
        self.init(icon: icon, symbol: symbol, tint: tint, title: title, subtitle: subtitle,
                  selected: selected, compact: compact, action: action) { EmptyView() }
    }
}

/// 分区标题
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(DS.cap(.semibold)).foregroundColor(DS.text.secondary)
            .textCase(nil).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(DS.separator).frame(height: 1) }
}

// MARK: - 页面标题
struct PageHeader<Trailing: View>: View {
    let title: String
    var sub: String = ""
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.title())
                if !sub.isEmpty { Text(sub).font(DS.sub()).foregroundColor(DS.text.secondary) }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, sub: String = "") { self.init(title: title, sub: sub) { EmptyView() } }
}

// MARK: - Toast
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let symbol: String
    let tint: Color
}

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var current: ToastMessage?
    private var work: DispatchWorkItem?
    func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: Color = good) {
        work?.cancel()
        let msg = ToastMessage(text: text, symbol: symbol, tint: tint)
        withAnimation(.easeOut(duration: DS.motionFast)) { current = msg }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: DS.motionFast)) { self?.current = nil }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: w)
    }
}

struct ToastHost: View {
    @ObservedObject var center = ToastCenter.shared
    var body: some View {
        VStack {
            Spacer()
            if let t = center.current {
                HStack(spacing: 8) {
                    Image(systemName: t.symbol).font(DS.body(.medium)).foregroundColor(t.tint)
                    Text(t.text).font(DS.body(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("toast")
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 搜索框
struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索页面、操作或进程"
    var autoFocus = false
    @FocusState private var focused: Bool
    var onSubmit: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(DS.body()).foregroundColor(DS.text.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(DS.body())
                .focused($focused)
                .onSubmit { onSubmit?() }
                .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(DS.sub()) }
                    .buttonStyle(.plain).foregroundColor(DS.text.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
            .strokeBorder(focused ? accent.opacity(0.7) : DS.border, lineWidth: 1))
        .onAppear { if autoFocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } } }
    }
}

// MARK: - 空状态
struct EmptyState: View {
    let symbol: String; let title: String; var sub: String = ""
    var body: some View {
        VStack(spacing: 6) {
            IconBadge(symbol: symbol, tint: good, size: 34)
            Text(title).font(DS.body(.medium))
            if !sub.isEmpty { Text(sub).font(DS.sub()).foregroundColor(DS.text.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
