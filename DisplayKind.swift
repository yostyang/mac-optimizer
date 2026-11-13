// 2.14 显示器标明内建还是外接：外接屏常用系统名称，多屏时分不清是哪块
import SwiftUI

extension DisplayInfo {
    var kindLabel: String { builtin ? "内建" : "外接" }
    /// 选择器里的名称：名字本身已经写明（例如「内建显示器」）时不重复
    var titleWithKind: String { name.contains(kindLabel) ? name : name + " · " + kindLabel }
}

struct DisplayKindTag: View {
    let builtin: Bool
    var body: some View {
        Text(builtin ? "内建" : "外接").font(DS.sub(.medium)).foregroundColor(DS.text.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            .accessibilityLabel(builtin ? "内建显示器" : "外接显示器").accessibilityIdentifier("disp.kind")
    }
}
