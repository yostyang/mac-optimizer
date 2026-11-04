// v2.0 界面优化：设计令牌（v20-fix 修订）
// 参考 https://github.com/Caho1/open-claude-ui（MIT 协议）只借圆角/动效/渐隐等非颜色原则，
// 不抄它的 React 代码、不搬专有字体/音频、不冒充 Claude。
// 颜色已按用户要求改回 v1.9 原配色：陶土橙不再作主色，原紫蓝主色、渐变侧边栏/面板头全部恢复，
// 只在原有配色基础上做圆角、动效、发丝细线、滚动渐隐、分段控件等优化，不换品牌色。
import SwiftUI
import AppKit

enum CDS {
    // 主色已改回 v1.9 原值（见 main.swift 的 accent/accent2），这里不再另存一份陶土橙，避免两套主色打架
    // 表面 0-3：0 页面、1 卡片，均为 v1.9 原值；2/3 保留作抬高层中性色，不再是 Claude 暖灰
    static let surface0 = dyn(NSColor(red: 0.958, green: 0.960, blue: 0.978, alpha: 1), NSColor(red: 0.105, green: 0.108, blue: 0.135, alpha: 1))
    static let surface1 = dyn(.white, NSColor(red: 0.165, green: 0.168, blue: 0.200, alpha: 1))
    static let surface2 = dyn(NSColor(red: 0.937, green: 0.937, blue: 0.945, alpha: 1), NSColor(red: 0.165, green: 0.168, blue: 0.200, alpha: 1))
    static let surface3 = dyn(NSColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1), NSColor(red: 0.208, green: 0.208, blue: 0.235, alpha: 1))
    // 圆角矩阵（v2.1 呼吸感：卡片/面板放软到 14，按钮 10，与 Muse 界面那种大圆角、轻阴影更接近；颜色不动）
    static let radiusOuter: CGFloat = 20
    static let radiusBubble: CGFloat = 18
    static let radiusPanel: CGFloat = 14
    static let radiusCard: CGFloat = 14
    static let radiusButton: CGFloat = 10
    // 动效令牌（秒）：微震 70ms、几何咬合 120ms、面板滑入 300ms
    static let motionMicro: Double = 0.07
    static let motionSettle: Double = 0.12
    static let motionPanel: Double = 0.30
    static let pressScale: CGFloat = 0.98
    static let breathe: Double = 2.4
    static let pulse: Double = 1.2
    // 深色下标题字重反向减细，避免文字发胀；浅色用 semibold，深色用 medium
    static func titleWeight(dark: Bool) -> Font.Weight { dark ? .medium : .semibold }
    // 滚动渐隐开关：内容高于视口才渐隐，放得下的页不加
    static func shouldFade(contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentHeight > viewportHeight + 1
    }
}

/// 主色呼吸点：充电/活动状态指示，不常驻采样，纯 SwiftUI 动画（颜色已改回原主色，不再是陶土橙）
struct ClayDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(accent).frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.35)
            .scaleEffect(on ? 1 : 0.8)
            .onAppear { withAnimation(.easeInOut(duration: CDS.breathe / 2).repeatForever(autoreverses: true)) { on = true } }
            .accessibilityHidden(true)
    }
}

/// 胶囊式分段轨道：999px 全圆角、2px 内边距，与原生 segmented 选择器同一视觉语言
struct SegmentedTrack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .background(Capsule().fill(accent.opacity(0.08)))
    }
}
