// v2.5：设计令牌、搜索索引、键盘操作、Toast、全局命令面板
import SwiftUI
import AppKit
import Carbon.HIToolbox

enum V25 {
    static func key(_ code: UInt16, _ chars: String = "", cmd: Bool = false, option: Bool = false) -> NSEvent {
        var f: NSEvent.ModifierFlags = []
        if cmd { f.insert(.command) }
        if option { f.insert(.option) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    static func tests() {
        MOTests.sec("设计基础（v2.5）")
        MOTests.check(DS.r.card == 12 && DS.r.control == 6 && DS.r.pill == 999, "圆角只有 3 种：卡片 12 / 控件 6 / 胶囊")
        MOTests.check(DS.fontSizes == [30, 22, 17, 13, 12.5, 12, 12, 12] && DS.fontSizes.allSatisfy { $0 >= 12 }, "字号统一：主值 30/22、标题 17、正文 13、标签 12.5、说明 12（无 10–11 pt 档）")
        MOTests.check(pageBG != cardBG, "页面与卡片是两层中性灰阶")
        MOTests.check(accent != accent2, "品牌紫与图表青蓝分开")
        MOTests.check(good != accent && warn != accent && bad != accent, "状态色独立于品牌色")
        MOTests.check(CDS.radiusCard == DS.r.card && CDS.radiusButton == DS.r.control, "旧令牌指向同一套圆角")

        MOTests.sec("搜索：页面 / 操作 / 进程")
        MOTests.check(!CmdIndex.pages("概览").isEmpty && CmdIndex.pages("概览").first?.id == "page.overview", "搜到页面")
        MOTests.check(CmdIndex.pages("电池").contains { $0.id == "page.battery" }, "搜到电池页")
        MOTests.check(!CmdIndex.actions("常亮").isEmpty, "搜到「常亮」操作")
        MOTests.check(!CmdIndex.actions("体检").isEmpty, "搜到「一键体检」")
        MOTests.check(!CmdIndex.actions("接显示器").isEmpty, "搜到「接显示器」")
        MOTests.check(CmdIndex.pages("zzzz不存在").isEmpty, "搜不到时返回空")
        MOTests.info("libproc 读到 \(ProcScan.all().count) 个进程")
        let procs = CmdIndex.processes("WindowServer")
        MOTests.check(!procs.isEmpty && procs.allSatisfy { $0.kind == .process && $0.title.lowercased().contains("windowserver") }, "按进程名搜索", "\(procs.count) 条")
        let finder = CmdIndex.processes("Finder")
        if let p = finder.first {
            MOTests.check(p.actions.contains { $0.destructive }, "普通 App 的进程项带「退出」操作")
        } else { MOTests.info("Finder 未运行，跳过破坏性操作检查") }
        MOTests.check(procs.allSatisfy { !$0.actions.isEmpty }, "系统进程也至少有「复制」操作")

        MOTests.sec("键盘操作")
        let shell = Shell.shared
        shell.query = "设置"
        MOTests.check(shell.items.count >= 2, "输入后出现结果", "\(shell.items.count) 项")
        shell.sel = 0
        MOTests.check(shell.handle(key(125)), "↓ 被消费"); MOTests.check(shell.sel == 1, "↓ 选中下一项")
        MOTests.check(shell.handle(key(126)) && shell.sel == 0, "↑ 回到上一项")
        MOTests.check(shell.handle(key(53)) && shell.query.isEmpty, "Esc 清空搜索")
        shell.query = "电池"
        MOTests.check(shell.handle(key(11, "k", cmd: true)) && shell.actionsFor != nil, "⌘K 打开操作面板")
        MOTests.check(shell.handle(key(53)) && shell.actionsFor == nil, "Esc 关闭操作面板")
        shell.query = "电池"; shell.sel = 0
        MOTests.check(shell.handle(key(48, "\t", cmd: true)) == false, "⌘Tab 不拦截")
        let before = Nav.shared.sel
        MOTests.check(shell.handle(key(19, "2", cmd: true)), "⌘2 切页"); MOTests.check(Nav.shared.sel == .monitor, "⌘2 打开实时监控")
        Nav.shared.sel = before
        shell.query = ""

        MOTests.sec("全局命令面板")
        MOTests.check(CommandPalette.label(code: 49, mods: UInt32(optionKey)) == "⌥Space", "默认快捷键显示为 ⌥Space")
        MOTests.check(CommandPalette.label(code: 49, mods: UInt32(cmdKey) | UInt32(optionKey)) == "⌥⌘Space", "组合键按 ⌃⌥⇧⌘ 顺序")
        CommandPalette.shared.open()
        MOTests.check(CommandPalette.shared.isOpen, "面板可以打开")
        CommandPalette.shared.close()
        MOTests.check(!CommandPalette.shared.isOpen, "面板可以关闭")

        MOTests.sec("Toast")
        ToastCenter.shared.show("测试提示")
        MOTests.check(ToastCenter.shared.current?.text == "测试提示", "Toast 立即出现")
        RunLoop.main.run(until: Date().addingTimeInterval(2.9))
        MOTests.check(ToastCenter.shared.current == nil, "2.6 秒后自动消失")
    }

    // MARK: 界面测试
    static func ui(_ w: NSWindow) {
        MOTests.sec("搜索与键盘操作（v2.5）")
        let shell = Shell.shared
        let pv = w.contentView!
        MOTests.check(MOTests.find(pv, id: "search.field") != nil, "顶部有搜索框")
        shell.query = "概览"
        MOTests.check(MOTests.waitUntil(2) { MOTests.find1(pv, label: "概览") != nil }, "搜索结果出现")
        shell.query = ""
        MOTests.settle(0.3)

        MOTests.sec("设置页（v2.5）")
        if let b = MOTests.find(pv, label: "设置") { b.press() }
        MOTests.check(MOTests.waitUntil(2) { Nav.shared.sel == .settings }, "侧边栏打开设置")
        MOTests.check(MOTests.find(pv, id: "set.hotkey") != nil && MOTests.find(pv, id: "set.menubar") != nil, "设置页有快捷键录制与菜单栏开关")
        let ka = KeepAwake.shared, before = KeepAwake.shared.on
        let saved = ka.defaults.object(forKey: KeepAwake.key)
        if let toggle = MOTests.find(pv, id: "set.awake") {
            toggle.press()
            MOTests.check(MOTests.waitUntil(1) { ka.on != before && ka.savedOn == ka.on }, "设置页常亮开关生效并保存启动状态")
            toggle.press()
            MOTests.check(MOTests.waitUntil(1) { ka.on == before }, "设置页常亮可关闭并恢复原断言状态")
        } else { MOTests.check(false, "设置页常亮开关") }
        if ka.on != before { before ? ka.startAssertion() : ka.stop() }
        if let saved { ka.defaults.set(saved, forKey: KeepAwake.key) } else { ka.defaults.removeObject(forKey: KeepAwake.key) }
        MOTests.check(MOTests.find(pv, id: "set.dock") != nil, "设置页有接显示器模式入口")
        Nav.shared.sel = .monitor
    }

    // MARK: 截图
    static func snapshots(_ out: String) {
        for (mode, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: ap)
            func shot<V: View>(_ v: V, _ name: String, w: CGFloat, h: CGFloat) {
                let host = NSHostingView(rootView: v.frame(width: w, height: h).background(DS.window))
                host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                let cw = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: false)
                cw.appearance = NSAppearance(named: ap); cw.contentView = host; cw.orderFrontRegardless(); MOTests.settle(1.0)
                if let rep = MOTests.pngRep(host, out + "/\(name)-\(mode).png") { MOTests.contrast(host, rep, "\(name) \(mode)") }
                if name != "tools25" { MOTests.fits(host, "\(name) \(mode)") }   // 资源排行是长列表：允许滚动，但不显示滚动条
                cw.orderOut(nil)
            }
            let content = Layout.minSize.width - 208
            shot(ToolPage(feature: features[0]), "tools25", w: content, h: Layout.minSize.height - 86)
            shot(SettingsPage(), "settings25", w: content, h: Layout.minSize.height - 86)
            Shell.shared.query = "edge"
            shot(SearchResults(), "search25", w: content, h: Layout.minSize.height - 86)
            Shell.shared.query = ""
        }
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}
