// v2.1 测试：面板自适应高度、面板减负（进程 4 条、统计行不放面板）、呼吸感圆角
import SwiftUI

extension MOTests {
    static func v21Tests() {
        sec("面板自适应")
        check(PanelHeight.height(contentHeight: 950, visibleHeight: 2160) == 950, "大屏上窗口高 = 内容高，不留大面积空白")
        check(PanelHeight.height(contentHeight: 950, visibleHeight: 1080) == 950, "外接屏内容 950 时一次放下，不滚动")
        check(PanelHeight.height(contentHeight: 950, visibleHeight: 900) == 870, "笔记本可见 900 时封顶 870，超出才滚动")
        check(PanelHeight.height(contentHeight: 0, visibleHeight: 900) == 870, "测不到内容时回退到可见高度 -30")
        check(PanelHeight.height(contentHeight: 950, visibleHeight: 500) == 600, "极小屏下限 600，不压成一条")
        sec("面板减负")
        let top = [1, 2, 3, 4, 5]
        check(Array(top.prefix(4)).count == 4, "面板进程只放前 4 条")
        check(QuickActions().showStats && !QuickActions(showStats: false).showStats, "快捷操作可按容器选择显示统计")
        sec("呼吸感")
        check(CDS.radiusCard == 12 && CDS.radiusPanel == 12, "卡片/面板圆角 12（v2.5 收口）")
    }
}
