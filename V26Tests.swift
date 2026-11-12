import AppKit
import SwiftUI

final class FakeScreens: SplitScreens {
    var displays: [SplitDisplay]; var primaryHeight: CGFloat
    init(_ d: [SplitDisplay], _ h: CGFloat) { displays = d; primaryHeight = h }
}
final class FakeWin { var frame: CGRect?; init(_ f: CGRect?) { frame = f } }
final class FakeDriver: SplitWindowDriver {
    var ok = true
    var focusedWin = FakeWin(CGRect(x: 100, y: 100, width: 800, height: 600))
    private var armed: FakeWin?
    var frame: CGRect? { get { focusedWin.frame } set { focusedWin.frame = newValue } }
    var armedWindow: AnyObject? { armed }
    func arm(_ w: AnyObject) -> CGRect? { guard let f = w as? FakeWin, f.frame != nil else { armed = nil; return nil }; armed = f; return f.frame }
    var minW: CGFloat = 0; var fixed = false; var moves = 0
    func trusted() -> Bool { ok }
    var pids: [pid_t] = []
    func focusedFrame(pid: pid_t) -> CGRect? { pids.append(pid); armed = frame == nil ? nil : focusedWin; return frame }
    func setFocused(_ r: CGRect) -> CGRect? {
        guard let w = armed else { return nil }
        guard !fixed, w.frame != nil else { return w.frame }
        moves += 1; w.frame = CGRect(x: r.minX, y: r.minY, width: max(r.width, minW), height: r.height); armed = nil; return w.frame
    }
}

final class FakeTracker: SplitAppTracker {
    var lastExternal: SplitTarget?; var reactivated: [pid_t] = []
    init(_ t: SplitTarget?) { lastExternal = t }
    func reactivate(_ t: SplitTarget) { reactivated.append(t.pid) }
}

enum V26 {
    static func tests() {
        typealias T = MOTests
        T.sec("分区布局数学（v2.6）")
        let vf = CGRect(x: 0, y: 0, width: 1608, height: 1000)
        let r3 = SplitLayout.rects(.threeCol, in: vf)
        T.check(r3.count == 3 && r3[0].minX == 8 && r3[2].maxX == 1600, "1:2:1 外边 8pt")
        T.check(abs(r3[1].minX - r3[0].maxX - 8) < 0.01 && abs(r3[2].minX - r3[1].maxX - 8) < 0.01, "1:2:1 栏间 8pt")
        T.check(abs(r3[1].width - 2 * r3[0].width) <= 1 && abs(r3[0].width - r3[2].width) <= 1, "1:2:1 比例 25/50/25")
        let r2 = SplitLayout.rects(.halves, in: vf)
        T.check(r2.count == 2 && abs(r2[0].width - r2[1].width) <= 1, "左右平分")
        let rt = SplitLayout.rects(.twoThirds, in: vf)
        T.check(abs(rt[0].width - 2 * rt[1].width) <= 1, "2/3 + 1/3")
        T.check(SplitLayout.rect(.halves, .center, in: vf) == nil && SplitLayout.rect(.halves, .right, in: vf) == r2[1], "两栏无中区、右区=末栏")
        T.check(r3.allSatisfy { $0.height == 984 && $0.minY == 8 }, "上下留 8pt")

        T.sec("坐标换算（v2.6）")
        // 主屏 1440x900；副屏在左侧、更高（负 x、负 AX y）
        let a = SplitLayout.toAX(CGRect(x: 0, y: 0, width: 1440, height: 875), primaryHeight: 900)
        T.check(a == CGRect(x: 0, y: 25, width: 1440, height: 875), "主屏 visibleFrame → AX（菜单栏 25pt）")
        let left = SplitLayout.toAX(CGRect(x: -1920, y: -180, width: 1920, height: 1080), primaryHeight: 900)
        T.check(left.minX == -1920 && left.minY == 0, "左侧副屏负 x 坐标")
        let above = SplitLayout.toAX(CGRect(x: 0, y: 900, width: 2560, height: 1440), primaryHeight: 900)
        T.check(above.minY == -1440, "上方副屏负 AX y")
        T.check(SplitLayout.fromAX(left, primaryHeight: 900) == CGRect(x: -1920, y: -180, width: 1920, height: 1080), "往返一致")

        T.sec("读回分类（v2.6）")
        let tg = CGRect(x: 8, y: 33, width: 600, height: 800)
        T.check(SplitLayout.classify(target: tg, actual: tg.offsetBy(dx: 1, dy: -1)) == .ok, "2pt 内算成功")
        T.check(SplitLayout.classify(target: tg, actual: CGRect(x: 8, y: 33, width: 700, height: 800)) == .sizeLimited, "宽度受限")
        T.check(SplitLayout.classify(target: tg, actual: CGRect(x: 500, y: 400, width: 800, height: 600)) == .notMovable, "没动=不可移动")
        T.check(SplitLayout.classify(target: tg, actual: nil) == .notMovable, "读不到=不可移动")

        T.sec("偏好与撤销（v2.6）")
        let suite = "mo.test.split.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!
        let p = SplitPrefs(ud)
        T.check(p.template("A") == nil, "默认关闭")
        p.set(.twoThirds, for: "A"); p.set(.halves, for: "B")
        T.check(SplitPrefs(UserDefaults(suiteName: suite)!).template("A") == .twoThirds && p.template("B") == .halves, "按 UUID 往返")
        p.set(nil, for: "A"); T.check(p.template("A") == nil && p.template("B") == .halves, "可关闭且不影响其它屏")
        let c = SplitController()
        let drv = FakeDriver()
        c.screens = FakeScreens([SplitDisplay(uuid: "M", name: "主屏", visible: CGRect(x: 0, y: 0, width: 1440, height: 875), scale: 2),
                                 SplitDisplay(uuid: "L", name: "左屏", visible: CGRect(x: -1920, y: -180, width: 1920, height: 1080), scale: 1)], 900)
        let trk = FakeTracker(SplitTarget(pid: 4242, name: "Chrome"))
        c.driver = drv; c.prefs = p; c.tracker = trk
        T.check(c.place(.left) == "这块屏幕还没选分区模板" && drv.moves == 0, "未选模板不移动")
        p.set(.threeCol, for: "M")
        T.check(c.place(.center) == "已把 Chrome 放到中区", "放到中区成功并点名应用")
        T.check(drv.pids.last == 4242 && trk.reactivated == [4242], "目标是最近的外部应用并交还焦点")
        T.check(drv.frame!.minY == 33 && abs(drv.frame!.midX - 720) <= 1, "中区位置正确（AX）")
        T.check(c.undoLast() == "已把 Chrome 撤销归位" && drv.frame == CGRect(x: 100, y: 100, width: 800, height: 600), "一步撤销")
        T.check(c.undoLast() == "没有可撤销的归位", "撤销只有一步")
        drv.frame = CGRect(x: -1500, y: 200, width: 600, height: 400); p.set(.halves, for: "L")
        _ = c.place(.right)
        T.check(drv.frame!.maxX == -8 && drv.frame!.minY == 8, "副屏（负坐标）右区")
        drv.minW = 2000; _ = c.place(.left)
        T.check(c.place(.left).hasSuffix("（尺寸受应用限制）"), "最小宽度→尺寸受限")
        drv.minW = 0; drv.fixed = true; drv.frame = CGRect(x: 300, y: 300, width: 500, height: 500)
        T.check(c.place(.left) == "「Chrome」的窗口不可移动", "固定窗口→不可移动")
        T.sec("目标应用跟踪（v2.6.1）")
        drv.fixed = false
        let wx = SplitTarget(pid: 777, name: "微信"); trk.lastExternal = wx; c.captured = nil
        c.captured = SplitTarget(pid: 555, name: "Code"); trk.lastExternal = wx
        _ = c.place(.left)
        T.check(drv.pids.last == 555 && trk.reactivated.last == 555, "面板打开时捕获的应用优先")
        T.check(c.captured == nil, "捕获只用一次")
        _ = c.place(.left); T.check(drv.pids.last == 777, "无捕获时用最近外部应用")
        trk.lastExternal = nil
        T.check(c.place(.left) == "没有找到要移动的应用窗口", "没有外部应用→明确提示")
        trk.lastExternal = wx; let f0 = drv.frame; drv.frame = nil
        T.check(c.place(.left) == "「微信」没有可移动的窗口", "应用无窗口→点名提示"); drv.frame = f0
        T.sec("撤销绑定具体窗口与空 ⌘K（v2.6.2）")
        drv.fixed = false; drv.minW = 0; c.captured = nil; trk.lastExternal = SplitTarget(pid: 900, name: "Chrome")
        let w1 = FakeWin(CGRect(x: 50, y: 60, width: 700, height: 500)); drv.focusedWin = w1
        _ = c.place(.left)
        let w2 = FakeWin(CGRect(x: 900, y: 60, width: 700, height: 500)); drv.focusedWin = w2   // 同一应用的另一个窗口成了焦点
        T.check(c.undoLast() == "已把 Chrome 撤销归位", "撤销成功")
        T.check(w1.frame == CGRect(x: 50, y: 60, width: 700, height: 500) && w2.frame == CGRect(x: 900, y: 60, width: 700, height: 500), "只还原当初移动的窗口，不动同应用的另一个窗口")
        drv.focusedWin = w1; _ = c.place(.right); w1.frame = nil   // 窗口被关闭
        T.check(c.undoLast().contains("已关闭") && w2.frame == CGRect(x: 900, y: 60, width: 700, height: 500), "原窗口已关闭→明确提示且不误移")
        T.check(c.undoLast() == "没有可撤销的归位", "关闭后撤销记录被清掉")
        let realPrefs = SplitController.shared.prefs; SplitController.shared.prefs = p   // 不受本机真实分区设置影响
        defer { SplitController.shared.prefs = realPrefs }
        T.check(Shell.contextItem(page: .split).actions.filter { $0.group == "分区" }.count == 4, "分区页空 ⌘K：「分区」组是左/中/右/撤销四个操作")
        T.check(!Shell.contextItem(page: .monitor).actions.contains { $0.group == "分区" }, "其它页没有分区操作")
        var hints: [String] = []; SplitHUD.sink = { hints.append($0) }
        let oldSel = Nav.shared.sel; Nav.shared.sel = .monitor
        let shl = Shell.shared; let oldQ = shl.query; shl.query = ""; shl.actionsFor = nil
        shl.openActions()
        T.check(hints.isEmpty && shl.actionsFor?.id == "ctx.monitor", "其它页空 ⌘K：打开当前页面的分组操作列表（2.13）")
        Nav.shared.sel = .split; shl.openActions()
        T.check(shl.actionsFor?.id == "ctx.split", "分区页空 ⌘K：打开分区操作面板")
        shl.actionsFor = nil; Nav.shared.sel = oldSel; shl.query = oldQ; SplitHUD.sink = nil

        let sh = SplitController.shared; let fd = FakeDriver(); fd.ok = false
        sh.driver = fd; sh.tracker = FakeTracker(nil)   // 绝不碰真实 AX
        var shown: [String] = []; SplitHUD.sink = { shown.append($0) }
        SplitController.commands("放到左区").first?.primary?.run()
        T.check(shown.count == 1 && shown[0].contains("辅助功能") && fd.moves == 0, "命令结果总会弹出提示"); SplitHUD.sink = nil
        SplitController.shared.captured = nil
        drv.ok = false; let n = drv.moves
        T.check(c.place(.left).contains("辅助功能") && drv.moves == n, "未授权：不调用、不崩溃")
        T.check(SplitController.commands("放到").count == 3 && SplitController.commands("撤销归位").count == 1, "命令面板有分区命令")
        ud.removePersistentDomain(forName: suite)
    }

    static func ui(_ w: NSWindow) {
        MOTests.sec("桌面分区页（v2.6）")
        let c = SplitController.shared
        let suite = "mo.uitest.split.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!
        c.prefs = SplitPrefs(ud)
        c.driver = FakeDriver(); c.tracker = FakeTracker(nil)   // 测试不碰真实 AX
        c.screens = FakeScreens([SplitDisplay(uuid: "T1", name: "测试屏", visible: CGRect(x: 0, y: 0, width: 1440, height: 875), scale: 2)], 900)
        let pv = w.contentView!
        Nav.shared.sel = .display
        MOTests.check(MOTests.waitUntil(2) { MOTests.find(pv, id: "disp.split") != nil }, "显示器页有「桌面分区」入口")
        MOTests.find(pv, id: "disp.split")?.press()
        MOTests.check(MOTests.waitUntil(2) { Nav.shared.sel == .split }, "打开桌面分区页")
        MOTests.check(MOTests.waitUntil(2) { MOTests.find(pv, id: "split.list") != nil && MOTests.find1(pv, id: "split.row.T1") != nil }, "列表显示屏幕")
        MOTests.find(pv, id: "split.tpl.21")?.press()
        MOTests.check(MOTests.waitUntil(2) { c.prefs.template("T1") == .twoThirds }, "点选模板后保存")
        MOTests.find(pv, id: "split.off")?.press()
        MOTests.check(MOTests.waitUntil(2) { c.prefs.template("T1") == nil }, "关闭分区可还原")
        (c.driver as? FakeDriver)?.ok = false
        Nav.shared.sel = .display; MOTests.settle(0.2); Nav.shared.sel = .split
        MOTests.check(MOTests.waitUntil(2) { MOTests.find(pv, id: "split.grant") != nil }, "未授权时显示权限引导")
        ud.removePersistentDomain(forName: suite)
        Nav.shared.sel = .monitor
    }
}
