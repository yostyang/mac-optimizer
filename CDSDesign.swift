// v2.0 界面优化：设计令牌
// 参考 https://github.com/Caho1/open-claude-ui（MIT 协议）只借圆角/动效/渐隐等非颜色原则，
// 不抄它的 React 代码、不搬专有字体/音频、不冒充 Claude。
// v2.5：颜色与圆角统一到 DS（V25Design.swift），这里只保留动效与渐隐开关，避免两套令牌打架。
import SwiftUI
import AppKit

enum CDS {
    // 表面色已迁到 DS.window / DS.card / DS.raised，这里保留别名给旧代码
    static let surface0 = DS.window
    static let surface1 = DS.card
    static let surface2 = DS.raised
    static let surface3 = DS.raised
    // 圆角只保留 3 种：卡片 12、控件 6、胶囊 999
    static let radiusOuter: CGFloat = DS.r.card
    static let radiusBubble: CGFloat = DS.r.card
    static let radiusPanel: CGFloat = DS.r.card
    static let radiusCard: CGFloat = DS.r.card
    static let radiusButton: CGFloat = DS.r.control
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
