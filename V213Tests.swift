// 2.13 P1 结构与密度：门槛 A 判定、面板偏好、侧栏分组、上下文动作、字号；界面交互与截图
import SwiftUI
import AppKit

enum V213 {
    typealias T = MOTests

    /// 人工搭一个 NSView 树：摘要标记 + 滚动区，验证门槛 A 判定本身（含反例）
    static func gateFixture(summaryInScroll: Bool = false, summaryTop: CGFloat = 0, summaryHeight: CGFloat = 120, scrollTop: CGFloat = 130, docHeight: CGFloat = 900) -> NSView {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let root = Flipped(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let sv = NSScrollView(frame: NSRect(x: 0, y: scrollTop, width: 600, height: 500 - scrollTop))
        sv.hasVerticalScroller = false
        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: 600, height: docHeight)); sv.documentView = doc
        root.addSubview(sv)
        let marker = SummaryMarkerView(frame: NSRect(x: 0, y: summaryTop, width: 600, height: summaryHeight))
        if summaryInScroll { doc.addSubview(marker) } else { root.addSubview(marker) }
        return root
    }

    static func tests() {
        T.sec("2.13 门槛 A：摘要不滚动，详情局部滚动")
        T.check(LayoutGate.evaluate(gateFixture()).problems.isEmpty, "摘要在上、详情区超出：允许（详情局部滚动）")
        T.check(!LayoutGate.evaluate(gateFixture(summaryInScroll: true)).problems.isEmpty, "摘要放进滚动区域：不通过")
        T.check(!LayoutGate.evaluate(gateFixture(summaryHeight: 560, scrollTop: 0)).problems.isEmpty, "摘要超出可见范围：不通过")
        T.check(!LayoutGate.evaluate(gateFixture(summaryTop: 300, summaryHeight: 100, scrollTop: 0)).problems.isEmpty, "摘要上方/旁边的滚动区超出：不通过")
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let sv = NSScrollView(frame: plain.bounds); sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600)); plain.addSubview(sv)
        T.check(!LayoutGate.evaluate(plain).problems.isEmpty, "没标摘要的页面沿用旧规则：超出即不通过")
        T.check(DS.fontSizes.allSatisfy { $0 >= 12 }, "设计令牌里没有小于 12 pt 的说明字号", DS.fontSizes.map { "\($0)" }.joined(separator: "/"))

        T.sec("2.13 侧栏分组")
        T.check(navGroups == ["状态", "日常控制", "整理与恢复", "全部工具", "设置"], "侧栏五组：状态 / 日常控制 / 整理与恢复 / 全部工具 / 设置")
        T.check(navPages.allSatisfy { navGroups.contains($0.group) }, "每一页都属于侧栏的某个组")
        T.check(navPages.first { $0.id == .network }?.group == "日常控制", "网络诊断在「日常控制」")
        T.check(navPages.filter { $0.group == "状态" }.map(\.id) == [.overview, .monitor, .battery], "「状态」只放概览、实时监控、电池")
        T.check(navPages.allSatisfy { p in CmdIndex.pages(p.title).contains { $0.id == "page.\(p.id.storageKey)" } }, "搜索仍能直达每一页（\(navPages.count) 页）")
        let order = navGroups.flatMap { g in navPages.filter { $0.group == g } }.map(\.id)
        T.check(order == navPages.map(\.id), "页面清单顺序与侧栏显示顺序一致（⌘1–9 按看到的顺序）")

        T.sec("2.13 面板快捷操作偏好")
        let suite = "mo.v213.prefs.\(getpid())"
        let d = UserDefaults(suiteName: suite)!; d.removePersistentDomain(forName: suite)
        let pp = PanelPrefs(d)
        T.check(pp.ids == ["act.mic", "act.awake", "act.charge", "act.dock"] && !pp.procExpanded, "默认 4 个快捷操作，进程默认收起", pp.ids.joined(separator: ","))
        T.check(pp.set("act.shot", on: true) && pp.ids.count == 5 && PanelPrefs(d).ids.contains("act.shot"), "可以加上截图，并会保存")
        for id in ["act.shot", "act.mic", "act.awake", "act.charge"] { pp.set(id, on: false) }
        T.check(pp.ids == ["act.dock"] && !pp.set("act.dock", on: false) && pp.ids == ["act.dock"], "至少保留 1 个")
        d.set(["act.unknown"], forKey: PanelPrefs.idsKey)
        T.check(PanelPrefs(d).ids == PanelPrefs.defaultIDs, "不认识的操作被丢弃，回到默认")
        pp.procExpanded = true; T.check(PanelPrefs(d).procExpanded, "进程展开状态会记住")
        pp.resetDefaults(); T.check(pp.ids.count == 4, "恢复默认 4 项")
        d.removePersistentDomain(forName: suite)
        T.check(Set(PanelPrefs.known) == Set(QuickActionList.all().map(\.id)), "偏好覆盖全部快捷操作")

        T.sec("2.13 上下文动作与分组 ⌘K")
        for p in [Page.overview, .monitor, .network, .clean] {
            T.check(!ContextActions.page(p).isEmpty, "「\(pageTitle(p))」底栏有常驻动作", ContextActions.page(p).map(\.title).joined(separator: "、"))
        }
        let item = ContextActions.item(.monitor)
        let groups = item.actions.compactMap(\.group).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        T.check(groups == ["当前页面", "快捷操作", "前往"], "⌘K 列表分三组且各组连续", groups.joined(separator: "→"))
        T.check(item.actions.filter { $0.group == "快捷操作" }.count == QuickActionList.all().count + 1, "快捷操作组含全部快捷操作 + 一键体检")
        T.check(!item.actions.contains { $0.title.contains("强制") }, "没有强制退出")
        T.check(ContextActions.item(.settings).actions.allSatisfy { $0.group != nil }, "每个操作都有分组")

        T.sec("2.13 菜单栏面板尺寸")
        T.check(PanelLayout.tileHeight == 72, "指标卡 72 pt", "\(Int(PanelLayout.tileHeight))")
        T.check(PanelHeight.height(contentHeight: 640, visibleHeight: 560) == 530, "矮屏（可见 560）面板封顶 530，内容滚动")
    }

    // MARK: 交互
    static func ui(_ w: NSWindow) {
        T.sec("2.13 底栏上下文动作与分组 ⌘K")
        Nav.shared.sel = .monitor; T.settle(0.8)
        let root = w.contentView!
        T.check(T.find1(root, id: "bottom.action.0") != nil, "实时监控底栏有常驻动作按钮")
        T.check(T.find1(root, id: "monitor.verdict") != nil && T.find1(root, id: "monitor.metrics") != nil && T.find1(root, id: "monitor.procs") != nil, "实时监控：结论、核心读数、进程列表都在")
        if let b = T.find1(root, id: "bottom.actions") {
            Shell.shared.query = ""
            b.press()
            T.check(T.waitUntil(2) { Shell.shared.actionsFor?.id == "ctx.monitor" }, "点「全部操作」打开当前页面的操作列表")
            T.settle(0.5)
            T.check(T.find1(root, id: "cmdk.group.当前页面") != nil && T.find1(root, id: "cmdk.group.快捷操作") != nil, "操作列表显示分组标题")
            Shell.shared.actionsFor = nil; T.settle(0.3)
        } else { T.check(false, "找到「全部操作」按钮") }

        T.sec("2.13 面板：快捷操作默认 4 个、进程默认收起")
        let prefs = PanelPrefs.shared; let oldIDs = prefs.ids, oldExp = prefs.procExpanded
        prefs.resetDefaults(); prefs.procExpanded = false
        let host = NSHostingView(rootView: PanelContent(m: Monitor.shared))
        let size = host.fittingSize; host.frame = NSRect(origin: .zero, size: size)
        let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        pw.contentView = host; pw.orderFrontRegardless(); T.settle(1.0)
        T.check(T.find1(host, id: "act.shot") == nil && T.find1(host, id: "act.clean") == nil && T.find1(host, id: "act.awake") != nil, "默认不显示截图、擦屏")
        T.check(T.find1(host, id: "proc.state") == nil, "进程默认收起（不展开列表）")
        if let t = T.find1(host, id: "panel.procs.toggle") {
            t.press(); T.check(T.waitUntil(2) { prefs.procExpanded }, "点标题展开进程列表")
            t.press(); T.check(T.waitUntil(2) { !prefs.procExpanded }, "再点收起")
        } else { T.check(false, "找到进程展开按钮") }
        prefs.set("act.shot", on: true); T.settle(0.6)
        T.check(T.find1(host, id: "act.shot") != nil, "在偏好里加上截图后，面板出现截图按钮")
        pw.orderOut(nil)
        prefs.resetDefaults(); for id in oldIDs { prefs.set(id, on: true) }
        for id in prefs.ids where !oldIDs.contains(id) { prefs.set(id, on: false) }
        prefs.procExpanded = oldExp
    }

    // MARK: 截图
    static func snapshots(_ out: String) {
        let mon = Monitor.shared
        let prefs = PanelPrefs.shared; prefs.resetDefaults(); prefs.procExpanded = false
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            // 门槛 B：矮屏幕（可见高度 520）上面板封顶并滚动
            let host = NSHostingView(rootView: PanelView(m: mon, visibleHeight: 520))
            host.frame = NSRect(origin: .zero, size: NSSize(width: PanelLayout.width, height: 490))
            let pw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: PanelLayout.width, height: 490), styleMask: [.titled], backing: .buffered, defer: false)
            pw.appearance = NSAppearance(named: ap); pw.contentView = host; pw.orderFrontRegardless(); T.settle(1.2)
            _ = T.pngRep(host, out + "/panel213-short-\(mode).png")
            var scrolls: [NSScrollView] = []
            func walk(_ v: NSView) { if let s = v as? NSScrollView { scrolls.append(s) }; v.subviews.forEach(walk) }
            walk(host)
            let over = scrolls.compactMap { s in s.documentView.map { $0.frame.height - s.contentView.bounds.height } }.max() ?? 0
            T.check(over > 1, "矮屏面板可以滚动 \(mode)", "窗口 490 pt，内容多出 \(Int(over)) pt")
            T.check(scrolls.allSatisfy { !($0.hasVerticalScroller && $0.scrollerStyle == .legacy && !($0.verticalScroller?.isHidden ?? true)) }, "矮屏面板不显示滚动条 \(mode)")
            pw.orderOut(nil)
            // 进程展开时的面板（只出截图，供人工查看）
            prefs.procExpanded = true
            let h2 = NSHostingView(rootView: PanelContent(m: mon))
            let s2 = h2.fittingSize; h2.frame = NSRect(origin: .zero, size: s2)
            let w2 = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: s2.width, height: s2.height), styleMask: [.titled], backing: .buffered, defer: false)
            w2.appearance = NSAppearance(named: ap); w2.contentView = h2; w2.orderFrontRegardless(); T.settle(1.0)
            _ = T.pngRep(h2, out + "/panel213-expanded-\(mode).png")
            T.check(s2.height <= 840, "展开进程后面板高度不超过 2.12 的默认高度 840 \(mode)", "\(Int(s2.height)) pt")
            w2.orderOut(nil)
            prefs.procExpanded = false
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}
