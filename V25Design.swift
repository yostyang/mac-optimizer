// v2.5 设计基础：中性灰阶 + 品牌紫（取自 App 图标那道紫→蓝弧线的紫）
// 只借鉴 Raycast 的交互模式（列表、⌘K、快捷键提示），不使用它的标志、图标与配色。
import SwiftUI
import AppKit

// MARK: - 令牌
enum DS {
    // 表面：中性灰阶。浅色偏白，深色接近图标的深蓝黑，不再大面积铺紫。
    static let window = dyn(NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1),
                            NSColor(srgbRed: 0.086, green: 0.086, blue: 0.165, alpha: 1))   // #F2F2F5 / #16162A
    static let card = dyn(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                          NSColor(srgbRed: 0.118, green: 0.118, blue: 0.200, alpha: 1))      // #FFFFFF / #1E1E33
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
    enum r { static let card: CGFloat = 10; static let control: CGFloat = 6; static let pill: CGFloat = 999 }

    // 字号只保留 4 档：标题 / 正文 13 / 次要 11 / 角标 10
    static let fontSizes: [CGFloat] = [17, 13, 11, 10]
    static func title(_ w: Font.Weight = .semibold) -> Font { .system(size: 17, weight: w) }
    static func body(_ w: Font.Weight = .regular) -> Font { .system(size: 13, weight: w) }
    static func sub(_ w: Font.Weight = .regular) -> Font { .system(size: 11, weight: w) }
    static func cap(_ w: Font.Weight = .medium) -> Font { .system(size: 10, weight: w) }
    /// 数字：等宽，避免刷新时跳动
    static func num(_ size: CGFloat = 13, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w, design: .rounded).monospacedDigit() }

    static let motionFast: Double = 0.12
    static let motionPanel: Double = 0.22
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
            .foregroundColor(on ? Color.white.opacity(0.85) : .secondary)
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
                    .foregroundColor(selected ? .white : .primary).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(DS.sub())
                        .foregroundColor(selected ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 32 : 44)
        .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
            .fill(selected ? AnyShapeStyle(accent) : (hovering ? AnyShapeStyle(DS.hover) : AnyShapeStyle(Color.clear))))
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
        Text(text).font(DS.cap(.semibold)).foregroundColor(.secondary)
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
                if !sub.isEmpty { Text(sub).font(DS.sub()).foregroundColor(.secondary) }
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
            Image(systemName: "magnifyingglass").font(DS.body()).foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(DS.body())
                .focused($focused)
                .onSubmit { onSubmit?() }
                .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(DS.sub()) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
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
            if !sub.isEmpty { Text(sub).font(DS.sub()).foregroundColor(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
