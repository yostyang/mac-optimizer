// 2.16 N1：对比度验收不依赖辅助功能树
//
// 文字/图形区域用「稳定布局标记」定位：`.contrastTarget(id, role)` 在目标背后铺一个真实、透明、不接收点击、
// 辅助功能忽略的 NSView（与 2.13 的 SummaryMarkerView 同一做法）。截图测试遍历 NSView 层级找到这些标记，
// 在真实渲染图里取样计算对比度；不读 AX 树，因此离屏窗口没有生成 SwiftUI 辅助功能树时检测照常进行。
//
// 发布版里 MOTests.active 恒为 false，修饰符不插入任何视图（零开销）；测试包启动时先置 active 再建界面。
import SwiftUI
import AppKit

/// 目标的检测口径（大小口径固定在这里，测试执行时不能按结果调整）
/// - text：普通文字 ≥ 4.5:1
/// - largeText：大字 ≥ 3:1。项目规范：≥ 18 pt，或 ≥ 14 pt 且字重 semibold 及以上（对应 WCAG 的 18pt / 14pt 粗体）
/// - graphic：承载含义的图形（电量条、状态点、低电量标记）≥ 3:1
enum ContrastRole: String, Codable {
    case text, largeText, graphic
    var threshold: Double { self == .text ? 4.5 : 3.0 }
    /// 由字号和字重换算口径：只认上面两条大字规则
    static func forFont(size: CGFloat, bold: Bool) -> ContrastRole { size >= 18 || (size >= 14 && bold) ? .largeText : .text }
}

final class ContrastMarkerView: NSView {
    var targetID = ""
    var role: ContrastRole = .text
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}
}

struct ContrastMarker: NSViewRepresentable {
    let id: String
    let role: ContrastRole
    func makeNSView(context: Context) -> ContrastMarkerView { let v = ContrastMarkerView(); v.targetID = id; v.role = role; return v }
    func updateNSView(_ v: ContrastMarkerView, context: Context) { v.targetID = id; v.role = role }
}

extension View {
    /// 标为对比度必测目标。id 用「组件.部位」或「组件.部位:内容」，同类目标可共用前缀
    @ViewBuilder func contrastTarget(_ id: String, _ role: ContrastRole = .text) -> some View {
        if MOTests.active {
            background(ContrastMarker(id: id, role: role).allowsHitTesting(false).accessibilityHidden(true))
        } else {
            self
        }
    }
}
