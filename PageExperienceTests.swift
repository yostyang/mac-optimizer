// 2.14 补齐页面体验：电池目标/实际、显示器内建/外接、分区百分比编辑、清理底栏与记录迁移、页面状态
import SwiftUI
import AppKit

enum PageExperienceTests {
    typealias T = MOTests

    static func status(enabled: Bool = true, limit: Int = 80, sail: Int = 5, adapterMode: Bool = true, topUp: Bool = false, inhibited: Bool = false,
                       adapterCut: Bool = false, plugged: Bool = true, level: Int? = 78, external: Bool? = nil, displayPaused: Bool? = nil, dock: Bool? = nil) -> ChargeStatus {
        ChargeStatus(settings: ChargeSettings(enabled: enabled, limit: limit, sail: sail), caps: adapterMode ? ChargeCaps(inhibit: .none, adapter: true) : ChargeCaps(inhibit: .chte, adapter: true),
                     topUp: topUp, inhibited: inhibited, adapterCut: adapterCut, level: level, plugged: plugged,
                     externalDisplay: external, displayPaused: displayPaused, dockProtected: dock)
    }

    static func tests() {
        T.sec("2.14 电池页：目标和实际分开，暂停原因一句话")
        typealias R = ChargeSummary.Reading
        let onAC = R(level: 78, charging: true, onAC: true)
        var s = ChargeSummary.make(phase: .ready, st: status(enabled: false), reading: onAC)
        T.check(s.target == "未启用 · 按系统默认充电" && s.actual == "78% · 正在充电" && s.pause == nil, "未启用：目标写系统默认，实际照常显示", "\(s.target) | \(s.actual)")
        s = ChargeSummary.make(phase: .ready, st: status(), reading: onAC)
        T.check(s.target == "上限 80%" && s.actual == "78% · 正在充电" && s.pause == nil && !s.holding, "充电中：目标 80%，实际 78% 正在充电", "\(s.target) | \(s.actual)")
        s = ChargeSummary.make(phase: .ready, st: status(inhibited: true, level: 80), reading: R(level: 80, onAC: true))
        T.check(s.actual == "80% · 保持在上限，暂停充电" && s.holding, "保持在上限：实际写明暂停充电", s.actual)
        s = ChargeSummary.make(phase: .ready, st: status(adapterCut: true, level: 80), reading: R(level: 80))
        T.check(s.actual == "80% · 用电池供电，降到 75% 再接通电源" && s.holding, "到上限断开电源：写明降到哪里再接通", s.actual)
        s = ChargeSummary.make(phase: .ready, st: status(external: true, displayPaused: true), reading: onAC)
        T.check(s.pause == "已暂停：接了外接显示器 · 拔掉后约 10 秒恢复上限" && s.target == "上限 80%", "显示器暂停：原因压成一句，目标不变", s.pause ?? "nil")
        s = ChargeSummary.make(phase: .ready, st: status(external: false, displayPaused: true), reading: onAC)
        T.check(s.pause == "外接显示器已拔掉 · 约 10 秒内恢复上限", "显示器刚拔掉：说明稍后恢复", s.pause ?? "nil")
        s = ChargeSummary.make(phase: .ready, st: status(dock: true), reading: onAC)
        T.check(s.pause?.hasPrefix("已暂停：保护扩展坞供电") == true && s.cardLine(enabled: true) == s.pause, "扩展坞暂停：电池页与充电卡同一句", s.pause ?? "nil")
        s = ChargeSummary.make(phase: .ready, st: status(adapterMode: false, external: true, displayPaused: true), reading: onAC)
        T.check(s.pause == nil, "有独立停充键的机型不会因外接屏暂停")
        s = ChargeSummary.make(phase: .ready, st: status(topUp: true), reading: onAC)
        T.check(s.target == "临时充到 100%" && s.actual.contains("恢复上限"), "临时充满：目标写 100%，实际说明之后恢复", "\(s.target) | \(s.actual)")
        s = ChargeSummary.make(phase: .notInstalled, st: status(inhibited: true), reading: R(level: 64))
        T.check(s.target == "系统默认（未启用充电助手）" && s.actual == "64% · 电池供电" && !s.holding, "没装助手：不显示助手的旧状态", "\(s.target) | \(s.actual)")
        s = ChargeSummary.make(phase: .unsupported, st: ChargeStatus(), reading: R(level: nil))
        T.check(s.target.contains("不支持") && s.actual.hasPrefix("电量未取得"), "读不到电量写「未取得」，不写 0", s.actual)
        T.check(ChargeSummary.make(phase: .ready, st: status(enabled: false), reading: onAC).cardLine(enabled: false) == "未启用 · 按系统默认充电", "充电卡关闭时说目标")

        T.sec("2.14 显示器：内建 / 外接")
        let mode = DMode(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refresh: 120)
        let inner = DisplayInfo(id: 1, name: "内建显示器", builtin: true, current: mode, modes: [mode])
        let lg = DisplayInfo(id: 2, name: "LG HDR 4K", builtin: false, current: mode, modes: [mode])
        let lg2 = DisplayInfo(id: 3, name: "LG HDR 4K", builtin: false, current: mode, modes: [mode])
        let retina = DisplayInfo(id: 4, name: "Built-in Retina Display", builtin: true, current: mode, modes: [mode])
        T.check(inner.titleWithKind == "内建显示器" && lg.titleWithKind == "LG HDR 4K · 外接", "名称里已写明时不重复，外接屏补上「外接」", "\(inner.titleWithKind) / \(lg.titleWithKind)")
        T.check(retina.titleWithKind == "Built-in Retina Display · 内建" && lg2.kindLabel == "外接", "英文系统名称也会补上内建 / 外接")

        T.sec("2.14 分区：百分比、5% 步进、拖动与输入")
        T.check(SplitCustom.percents([1, 3, 3, 1]) == [13, 38, 37, 12] && SplitCustom.percents([1, 9, 9, 9]).allSatisfy { $0 >= 10 }, "旧的 1–9 比例换成百分比，单栏不少于 10%", "\(SplitCustom.percents([1, 3, 3, 1]))")
        T.check(SplitCustom.moveDivider([33, 67], 0, by: 5) == [35, 65] && SplitCustom.moveDivider([33, 67], 0, by: -5) == [30, 70], "键盘每次 5%，不在刻度上时先对齐到刻度")
        T.check(SplitCustom.moveDivider([30, 70], 0, by: 1, snap: false) == [31, 69], "⇧ 每次 1%")
        T.check(SplitCustom.moveDivider([10, 90], 0, by: -5) == [10, 90] && SplitCustom.moveDivider([20, 70, 10], 1, by: 5) == [20, 70, 10], "到 10% 下限后不再缩小")
        T.check(SplitCustom.moveDivider([25, 50, 25], 1, by: 5) == [25, 55, 20], "只改分隔线两侧的栏，其他栏不动")
        T.check(SplitCustom.dragDivider([50, 50], 0, to: 0.32) == [30, 70] && SplitCustom.dragDivider([50, 50], 0, to: 0.32, snap: false) == [32, 68], "拖动吸附到 5%，按住 ⌥ 不吸附")
        T.check(SplitCustom.dragDivider([25, 50, 25], 1, to: 0.6) == [25, 35, 40] && SplitCustom.dragDivider([25, 50, 25], 1, to: 0.99) == [25, 65, 10], "拖第二条分隔线按整块宽度算，拖到边上停在 10%")
        T.check(SplitCustom.set([25, 50, 25], column: 0, to: 40) == .ok([40, 35, 25]), "输入数字：差额由右边相邻栏补")
        T.check(SplitCustom.set([25, 50, 25], column: 2, to: 30) == .ok([25, 45, 30]), "最后一栏由左边相邻栏补")
        if case .rejected(let why) = SplitCustom.set([25, 50, 25], column: 0, to: 70) { T.check(why == "第 1 栏最多 65%：第 2 栏至少要留 10%", "超出范围时拒绝并说明原因", why) } else { T.check(false, "超出范围时拒绝") }
        T.check(SplitCustom.set([50, 50], column: 0, to: 5) == .rejected("每栏至少 10%"), "低于 10% 拒绝")

        T.sec("2.14 分区：旧设置迁移")
        let suite = "mo.test.split214.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        ud.set(["A": [1, 2, 1], "B": [0, 3]], forKey: "split.custom"); ud.set(["A": [1, 2, 1]], forKey: "split.customRows")
        let p = SplitPrefs(ud)
        T.check(p.custom("A") == [25, 50, 25] && p.rows("A") == [1, 2, 1] && p.title("A") == "自定义 25% : 50% : 25%", "2.13 的 1 : 2 : 1 读成 25% / 50% / 25%，上下平分保留")
        T.check(p.custom("B") == nil, "旧版不合法的设置忽略")
        p.setCustom([30, 40, 30], for: "A")
        T.check(p.custom("A") == [30, 40, 30] && (ud.dictionary(forKey: "split.custom") as? [String: [Int]])?["A"] == [1, 2, 1], "保存新比例到新键，旧键不动（可回退旧版）")
        p.set(.halves, for: "A")
        T.check(p.custom("A") == nil && (ud.dictionary(forKey: "split.custom") as? [String: [Int]])?["A"] == nil, "选回固定模板时新旧自定义一起清掉")
        ud.removePersistentDomain(forName: suite)

        T.sec("2.14 清理页底栏与记录迁移")
        T.check(CleanSummary.line(selected: 3, bytes: 1_288_490_188, failures: 0) == "已选 3 项 · 共 \(CleanLogic.fmtSize(1_288_490_188))", "底栏汇总：已选数量与合计大小")
        T.check(CleanSummary.line(selected: 2, bytes: 1024, failures: 1).hasSuffix(" · 1 项未完成"), "有失败项时汇总里写明")
        T.check(CleanSummary.button(selected: 3, failures: 0, trashing: false) == "移到废纸篓（3 项）" && CleanSummary.button(selected: 3, failures: 1, trashing: false) == "重试所选未完成项"
                && CleanSummary.button(selected: 3, failures: 0, trashing: true) == "处理中…", "主按钮文案随状态变化")
        let legacy = ChangeRecord(kind: .clean, title: "清理到废纸篓：a.dmg", detail: "", reversible: true, restoreNote: "在「清理预览」的操作记录里点恢复")
        T.check(ChangesPage.restoreText(legacy) == CleanRecordsCard.restoreHint, "旧记录里「去清理预览恢复」的说明改指向改动记录页")
        let other = ChangeRecord(kind: .dns, title: "DNS", detail: "", reversible: false, restoreNote: "恢复说明")
        T.check(ChangesPage.restoreText(other) == "恢复说明", "其他记录的说明不变")

        T.sec("2.14 其余页面的统一状态")
        T.check(UninstallTab.noteKind("正在列出残留…", busy: true) == .loading && UninstallTab.noteKind("已移到废纸篓 3 项，可在下方记录里恢复", busy: false) == .done
                && UninstallTab.noteKind("已移到废纸篓 2 项；1 项没有移动（可能需要管理员权限或受保护），已保留", busy: false) == .failed
                && UninstallTab.noteKind("DemoApp 正在运行：请先自己退出它", busy: false) == .unknown, "卸载提示分成进行中 / 完成 / 部分失败 / 需要先处理")
        let op = ToolOperation(); op.verificationTimeout = 0.3
        var done: Bool?
        op.perform(Row(icon: nil, title: "测试项", subtitle: "", actionTitle: "处理", action: {}, verify: { true })) { ok, _ in done = ok }
        T.check(op.stateKind == .loading, "工具页操作进行中显示「正在」")
        T.check(T.waitUntil(3) { done != nil } && op.stateKind == .done, "核对完成后显示「已完成」")
        done = nil
        op.perform(Row(icon: nil, title: "测试项", subtitle: "", actionTitle: "处理", action: {}, verify: { false })) { ok, _ in done = ok }
        T.check(T.waitUntil(3) { done != nil } && op.stateKind == .unknown, "没能核对时显示「未取得」并给刷新，不算完成")
    }

    // MARK: 交互
    static func ui(_ w: NSWindow) {
        let root = w.contentView!
        T.sec("2.14 分区：键盘 / 辅助功能调分隔线")
        let c = SplitController.shared
        let suite = "mo.uitest.split214.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        let keepPrefs = c.prefs, keepDriver = c.driver, keepScreens = c.screens
        c.prefs = SplitPrefs(ud); c.driver = FakeDriver()
        c.screens = FakeScreens([SplitDisplay(uuid: "T2", name: "测试屏", visible: CGRect(x: 0, y: 0, width: 1440, height: 875), scale: 2)], 900)
        c.prefs.setCustom([25, 50, 25], for: "T2")
        Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .split
        if let d = T.find(root, id: "split.divider.0") {
            let inc = NSSelectorFromString("accessibilityPerformIncrement")
            if d.o.responds(to: inc) { _ = d.o.perform(inc) }
            T.check(T.waitUntil(2) { c.prefs.custom("T2") == [30, 45, 25] }, "分隔线加一档：左栏 25% → 30%，只动相邻两栏", "\(String(describing: c.prefs.custom("T2")))")
            T.check(T.axString(d.o, "accessibilityLabel").contains("分隔线"), "分隔线有朗读名称")
        } else { T.check(false, "找到第一条分隔线") }
        T.check(T.find1(root, id: "split.custom.pct.0") != nil && T.find1(root, id: "split.custom.hint") != nil, "每栏有百分比输入框，提示文案已更新")
        c.prefs = keepPrefs; c.driver = keepDriver; c.screens = keepScreens; ud.removePersistentDomain(forName: suite)

        T.sec("2.14 改动记录页：清理记录可以恢复")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("mo-restore-214-\(getpid())")
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp.appendingPathComponent("trash"), withIntermediateDirectories: true)
        let trashed = tmp.appendingPathComponent("trash/示例.txt"), original = tmp.appendingPathComponent("orig/示例.txt")
        try? Data("x".utf8).write(to: trashed)
        let store = CleanStore.shared, keepRecords = store.records, keepNote = store.restoreNote
        let rec = CleanRecord(date: Date(), path: original.path, size: 1, trashed: true, trashPath: trashed.path)
        store.records = [rec]; store.restoreNote = ""
        Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .changes
        if let b = T.find(root, id: "clean.restore." + rec.id.uuidString) {
            b.press()
            T.check(T.waitUntil(2) { fm.fileExists(atPath: original.path) && store.records.first?.restored == true }, "在改动记录页点恢复：文件放回原位置，记录标为已恢复")
            T.check(T.find(root, id: "clean.restore.state") != nil, "恢复结果用统一状态显示")
        } else { T.check(false, "改动记录页有清理记录的恢复按钮") }
        store.records = keepRecords; store.restoreNote = keepNote; try? fm.removeItem(at: tmp)
        Nav.shared.sel = .clean
        T.check(T.find(root, id: "clean.scan") != nil && T.find1(root, id: "clean.restore." + rec.id.uuidString) == nil, "清理页不再显示恢复按钮")

        T.sec("2.14 电池页与显示器页")
        if Monitor.shared.s.battery != nil {
            Nav.shared.sel = .battery
            T.check(T.find(root, id: "bat.target") != nil && T.find1(root, id: "bat.actual") != nil, "电池页顶部分开显示目标和实际")
        } else { T.info("这台 Mac 没有电池，跳过电池页目标 / 实际") }
        if !DisplayManager.shared.displays.isEmpty {
            Nav.shared.sel = .display
            T.check(T.find(root, id: "disp.kind") != nil, "显示器标题旁标明内建或外接")
        }
        Nav.shared.sel = .monitor
    }

    // MARK: 截图
    static func snapshots(_ out: String) {
        let store = CleanStore.shared, keepItems = store.items, keepNote = store.note
        let cats = ["缓存", "日志", "安装包"]
        var fixture: [CleanItem] = []
        for i in 0..<30 {
            let size: Int64 = Int64(50 + i * 7) * 1_048_576
            fixture.append(CleanItem(category: cats[i % 3], path: "/Users/me/Library/Caches/示例-\(i)", size: size, selected: i % 4 != 0))
        }
        store.items = fixture
        store.note = "已扫到 30 项，勾选后点“移到废纸篓”才会动"
        defer { store.items = keepItems; store.note = keepNote }
        let summary = ChargeSummary.make(phase: .ready, st: status(external: true, displayPaused: true), reading: .init(level: 78, charging: true, onAC: true))
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            // 最小窗口里的长清单：底栏必须完整在窗口内，清单局部滚动
            let size = NSSize(width: Layout.minSize.width - 212, height: Layout.minSize.height)
            let host = NSHostingView(rootView: CleanPage().frame(width: size.width, height: size.height).background(pageBG))
            host.frame = NSRect(origin: .zero, size: size)
            let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
            cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); T.settle(1.0)
            _ = T.pngRep(host, out + "/clean214-long-\(mode).png")
            var markers: [NSView] = [], scrolls: [NSScrollView] = []
            func walk(_ v: NSView) { if v is PinnedFooterMarkerView { markers.append(v) }; if let s = v as? NSScrollView { scrolls.append(s) }; v.subviews.forEach(walk) }
            walk(host)
            let inside = markers.first.map { host.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: host)) } ?? false
            let over = scrolls.compactMap { s in s.documentView.map { $0.frame.height - s.contentView.bounds.height } }.max() ?? 0
            T.check(inside && over > 1, "最小窗口长清单：底栏固定在窗口内，清单局部滚动 \(mode)", "底栏标记 \(markers.count) 个，清单多出 \(Int(over)) pt")
            T.fits(host, "clean214-long \(mode)")
            cw.orderOut(nil)
            // 电池页顶部：目标 / 实际 / 暂停一句
            let h2 = NSHostingView(rootView: ChargeSummaryRow(sum: summary).padding(16).frame(width: 640).background(pageBG))
            let s2 = h2.fittingSize; h2.frame = NSRect(origin: .zero, size: s2)
            let w2 = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: s2.width, height: s2.height), styleMask: [.titled], backing: .buffered, defer: false)
            w2.appearance = NSAppearance(named: ap); w2.contentView = h2; w2.orderFrontRegardless(); T.settle(0.6)
            _ = T.pngRep(h2, out + "/charge214-summary-\(mode).png")
            w2.orderOut(nil)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}
