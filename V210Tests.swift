// 2.10 测试：按住 ⇧ 拖动窗口到分区
import AppKit

final class FakeDragSource: DragWindowSource {
    var ok = true
    var win: FakeWin? = FakeWin(CGRect(x: 100, y: 100, width: 800, height: 600))
    var follow = true                 // 窗口是否跟着鼠标移动
    var resizing = false              // 模拟拖的是窗口边缘（尺寸在变）
    var atCalls = 0, frameCalls = 0
    private var base = CGPoint.zero, start = CGRect.zero
    func begin(at p: CGPoint) { base = p; start = win?.frame ?? .zero }
    /// 鼠标移动到 p：按设定更新窗口
    func move(to p: CGPoint) {
        guard let w = win else { return }
        let d = CGPoint(x: p.x - base.x, y: p.y - base.y)
        if resizing { w.frame = CGRect(x: start.minX, y: start.minY, width: start.width + d.x, height: start.height + d.y) }
        else if follow { w.frame = start.offsetBy(dx: d.x, dy: d.y) }
    }
    func trusted() -> Bool { ok }
    func window(at p: CGPoint) -> DragWindow? {
        atCalls += 1
        guard ok, let w = win, let f = w.frame else { return nil }
        return DragWindow(handle: w, pid: 4242, name: "Chrome", frame: f)
    }
    func frame(of h: AnyObject) -> CGRect? { frameCalls += 1; return (h as? FakeWin)?.frame }
}

enum V210 {
    typealias T = MOTests
    static func tests() {
        T.sec("2.10 拖动到分区：手势判断")
        let zones = [CGRect(x: 8, y: 33, width: 400, height: 800), CGRect(x: 416, y: 33, width: 800, height: 800), CGRect(x: 1224, y: 33, width: 400, height: 800)]
        let zonesAt: (CGPoint) -> [CGRect] = { _ in zones }
        /// 从 from 拖到 to，分 steps 步；返回松手结果
        func drag(_ s: FakeDragSource, from: CGPoint, to: CGPoint, steps: Int = 8, shift: (Int) -> Bool = { _ in true }, shiftUp: Bool = true,
                  inspect: ((DragGesture) -> Void)? = nil) -> (DragGesture.Drop?, Int) {
            var g = DragGesture(); g.mouseDown(from); s.begin(at: from)
            for i in 1...steps {
                let p = CGPoint(x: from.x + (to.x - from.x) * CGFloat(i) / CGFloat(steps), y: from.y + (to.y - from.y) * CGFloat(i) / CGFloat(steps))
                s.move(to: p); g.mouseDragged(p, shift: shift(i), source: s, zonesAt: zonesAt)
                if i == steps { inspect?(g) }
            }
            let d = g.mouseUp(to, shift: shiftUp, zonesAt: zonesAt)
            return (d, g.queries)
        }
        var s = FakeDragSource()
        var seen: DragGesture?
        var r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 400), inspect: { seen = $0 })
        T.check(seen?.phase == .dragging && seen?.active == 1 && seen?.zones == zones, "按住 ⇧ 拖窗口：认出拖动并高亮鼠标所在的区")
        T.check(r.0?.zone == 1 && r.0?.target == zones[1], "松手落在中间的区")
        T.check(r.0?.original == CGRect(x: 100, y: 100, width: 800, height: 600), "撤销位置 = 拖动前的位置（按鼠标位移反推）", "\(String(describing: r.0?.original))")
        T.check(r.1 == 2, "一次手势只做两次查询（取窗口 + 确认跟随）", "\(r.1)")

        s = FakeDragSource()
        r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 400), shift: { _ in false }, shiftUp: false)
        T.check(r.0 == nil && s.atCalls == 0 && s.frameCalls == 0, "不按 ⇧：不做任何查询，也不移动窗口")

        s = FakeDragSource()
        r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 400), shiftUp: false)
        T.check(r.0 == nil, "松手前放开 ⇧：取消，不移动窗口")

        s = FakeDragSource()
        seen = nil
        r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 400), shift: { $0 >= 5 }, inspect: { seen = $0 })
        T.check(r.0?.zone == 1 && r.0?.original == CGRect(x: 100, y: 100, width: 800, height: 600), "拖到一半才按 ⇧：照样生效，撤销位置仍是拖动前", "\(String(describing: r.0?.original))")

        s = FakeDragSource(); s.follow = false
        seen = nil
        r = drag(s, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 800, y: 400), inspect: { seen = $0 })
        T.check(r.0 == nil && seen?.phase == .rejected && s.frameCalls <= DragGesture.maxQueries, "窗口没跟着动（在选文字或拖文件）：鼠标走远后放弃，不再查询", "查询 \(s.frameCalls) 次")

        // 真机上窗口位置的读数比鼠标慢：只跟上一半也要认出来
        final class Laggy: DragWindowSource {
            let inner: FakeDragSource; var stale: CGRect?
            init(_ s: FakeDragSource) { inner = s }
            func trusted() -> Bool { true }
            func window(at p: CGPoint) -> DragWindow? { inner.window(at: p) }
            func frame(of h: AnyObject) -> CGRect? { let now = inner.frame(of: h); defer { stale = now }; return stale ?? now }
        }
        s = FakeDragSource()
        do {
            let lag = Laggy(s); var g = DragGesture(); let from = CGPoint(x: 300, y: 110); g.mouseDown(from); s.begin(at: from)
            for i in 1...10 { let p = CGPoint(x: 300 + CGFloat(i) * 40, y: 110 + CGFloat(i) * 20); s.move(to: p); g.mouseDragged(p, shift: true, source: lag, zonesAt: zonesAt) }
            T.check(g.phase == .dragging, "窗口位置读数慢一拍：仍能认出是在拖窗口", "\(g.phase)，查询 \(g.queries) 次")
        }
        T.check(DragGesture.originalFrame(down: CGPoint(x: 300, y: 110), up: CGPoint(x: 800, y: 400), frameAtUp: CGRect(x: 600, y: 390, width: 800, height: 600)) == CGRect(x: 100, y: 100, width: 800, height: 600), "撤销位置按松手后的窗口位置反推")

        s = FakeDragSource(); s.resizing = true
        seen = nil
        r = drag(s, from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1000, y: 780), inspect: { seen = $0 })
        T.check(r.0 == nil && seen?.phase == .rejected, "在调整窗口大小：不触发")

        s = FakeDragSource(); s.win = nil
        r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 400))
        T.check(r.0 == nil && s.atCalls == 1, "鼠标下没有可移动的窗口：只查一次就放弃")

        s = FakeDragSource()
        r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 20))
        T.check(r.0 == nil, "松手位置不在任何区里：不移动窗口")

        s = FakeDragSource()
        var g = DragGesture(); g.mouseDown(CGPoint(x: 300, y: 110)); s.begin(at: CGPoint(x: 300, y: 110))
        g.mouseDragged(CGPoint(x: 302, y: 111), shift: true, source: s, zonesAt: zonesAt)
        T.check(g.phase == .pressed && s.atCalls == 0, "鼠标只抖动了几个点：不算拖动")
        g = DragGesture()
        g.mouseDragged(CGPoint(x: 500, y: 500), shift: true, source: s, zonesAt: zonesAt)
        T.check(g.phase == .idle && g.mouseUp(CGPoint(x: 500, y: 500), shift: true, zonesAt: zonesAt) == nil, "没有按下就收到拖动事件：忽略")

        T.sec("2.10 拖动到分区：归位与撤销")
        let c = SplitController()
        let drv = FakeDriver(); c.driver = drv
        c.screens = FakeScreens([SplitDisplay(uuid: "A", name: "内建", visible: CGRect(x: 0, y: 0, width: 1632, height: 875), scale: 2)], 900)
        c.tracker = FakeTracker(SplitTarget(pid: 4242, name: "Chrome"))
        let win = FakeWin(CGRect(x: 600, y: 390, width: 800, height: 600))
        let drop = DragGesture.Drop(window: DragWindow(handle: win, pid: 4242, name: "Chrome", frame: win.frame!), original: CGRect(x: 100, y: 100, width: 800, height: 600), target: zones[1], zone: 1, down: .zero, up: .zero)
        T.check(c.placeDragged(drop) == "已把 Chrome 放到第 2 区" && win.frame == zones[1], "松手后窗口放进落区", "\(String(describing: win.frame))")
        T.check(c.undoLast() == "已把 Chrome 撤销归位" && win.frame == CGRect(x: 100, y: 100, width: 800, height: 600), "撤销回到拖动前的位置，而不是松手时的位置")
        drv.minW = 1000
        T.check(c.placeDragged(drop).hasSuffix("（尺寸受应用限制）"), "应用有最小宽度：照常提示尺寸受限")
        win.frame = nil
        T.check(c.placeDragged(drop) == "「Chrome」的窗口已关闭", "窗口在松手前关闭：给出说明")
        drv.ok = false
        T.check(c.placeDragged(drop) == "需要先授予“辅助功能”权限", "没有辅助功能权限：给出说明")
        T.check(!DragZones.shared.running, "自检时不启动全局鼠标监听")

        T.sec("2.10 自定义分区比例")
        T.check(SplitCustom.valid([1, 2]) && SplitCustom.valid([3, 5, 2, 1]) && !SplitCustom.valid([1]) && !SplitCustom.valid([1, 1, 1, 1, 1]) && !SplitCustom.valid([0, 2]) && !SplitCustom.valid([1, 10]), "2 到 4 栏、每栏 1 到 9")
        T.check(SplitCustom.seed(from: [1, 2, 1]) == [1, 2, 1] && SplitCustom.seed(from: nil) == [1, 1], "从当前模板的比例开始调整")
        T.check(SplitCustom.adjust([1, 2, 1], column: 1, by: 1) == [1, 3, 1] && SplitCustom.adjust([1, 2], column: 0, by: -1) == [1, 2] && SplitCustom.adjust([9, 2], column: 0, by: 1) == [9, 2], "每栏加减且不越界")
        T.check(SplitCustom.addColumn([1, 2]) == [1, 2, 1] && SplitCustom.addColumn([1, 1, 1, 1]).count == 4 && SplitCustom.removeColumn([1, 2, 1]) == [1, 2] && SplitCustom.removeColumn([1, 2]) == [1, 2], "加栏减栏有上下限")
        let vf = CGRect(x: 0, y: 0, width: 1608, height: 1000)
        let r4 = SplitLayout.rects(weights: [1, 3, 3, 1], in: vf)
        T.check(r4.count == 4 && r4[0].minX == 8 && r4[3].maxX == 1600 && abs(r4[1].width - 3 * r4[0].width) <= 2, "四栏 1:3:3:1 的布局", "\(r4.map { Int($0.width) })")
        T.check(SplitLayout.rects(.threeCol, in: vf) == SplitLayout.rects(weights: [1, 2, 1], in: vf), "固定模板与同比例的自定义结果一致")
        let suite = "mo.test.split210.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        let p = SplitPrefs(ud)
        p.set(.halves, for: "A")
        T.check(p.weights("A") == [1, 1] && p.custom("A") == nil && p.title("A") == "左右平分", "老用户已选的固定模板照常生效")
        p.setCustom([2, 3, 1], for: "A")
        T.check(p.template("A") == nil && p.custom("A") == [2, 3, 1] && p.weights("A") == [2, 3, 1] && p.title("A") == "自定义 2 : 3 : 1", "改用自定义后替换固定模板")
        p.setCustom([1], for: "A"); T.check(p.custom("A") == [2, 3, 1], "不合法的比例不保存")
        p.set(.twoThirds, for: "A"); T.check(p.custom("A") == nil && p.weights("A") == [2, 1], "选回固定模板后清掉自定义")
        p.setCustom([1, 2, 2, 1], for: "B"); p.set(nil, for: "B"); T.check(p.weights("B") == nil, "关闭分区同时清掉自定义")
        p.setCustom([1, 3, 3, 1], for: "A")
        c.prefs = p; drv.ok = true; drv.minW = 0
        let w4 = FakeWin(CGRect(x: 100, y: 100, width: 500, height: 400)); drv.focusedWin = w4
        T.check(c.place(index: 1) == "已把 Chrome 放到第 2 区" && abs(w4.frame!.minX - SplitLayout.rects(weights: [1, 3, 3, 1], in: CGRect(x: 0, y: 0, width: 1632, height: 875))[1].minX) <= 1, "四栏：按序号放到第 2 区")
        T.check(c.place(.right).hasPrefix("已把 Chrome 放到右区") && c.place(.left).hasPrefix("已把 Chrome 放到左区"), "四栏：左区 = 第一栏，右区 = 最后一栏")
        T.check(c.place(.center) == "当前模板没有中区" && c.place(index: 4) == "当前模板没有第 5 区", "四栏没有唯一的中区：给出说明")
        let shared = SplitController.shared, keepPrefs = shared.prefs, keepScreens = shared.screens
        shared.prefs = p; shared.screens = c.screens
        T.check(SplitController.commands("放到").count == 5, "有四栏模板时命令面板多出第 2、3 区", "\(SplitController.commands("放到").map(\.title))")
        p.setCustom([1, 2, 1], for: "A")
        T.check(SplitController.commands("放到").count == 3, "三栏及以下只有左中右")
        shared.prefs = keepPrefs; shared.screens = keepScreens
        ud.removePersistentDomain(forName: suite)

        T.sec("2.10 清理记录恢复")
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "mo-restore-\(getpid())"
        try? fm.removeItem(atPath: root)
        let home = root + "/原目录", trash = root + "/废纸篓"
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true); try? fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
        func rec(_ name: String, trashed: Bool = true) -> CleanRecord {
            if trashed { fm.createFile(atPath: trash + "/" + name, contents: Data(name.utf8)) }
            return CleanRecord(date: Date(), path: home + "/" + name, size: 3, trashed: true, trashPath: trash + "/" + name)
        }
        var r1 = rec("报告.pdf")
        T.check(CleanRestore.status(r1) == .available, "还在废纸篓里：可以恢复")
        T.check(CleanRestore.restore(r1) == .restored(home + "/报告.pdf") && fm.fileExists(atPath: home + "/报告.pdf") && !fm.fileExists(atPath: trash + "/报告.pdf"), "恢复到原位置")
        T.check(CleanRestore.status(r1) == .trashGone, "恢复后废纸篓里已不在")
        r1.restored = true; T.check(CleanRestore.status(r1) == .restored && CleanRestore.restore(r1) == .failed("这一项已经恢复过了"), "已恢复的记录不能重复恢复")
        let r2 = rec("报告.pdf")
        T.check(CleanRestore.restore(r2) == .renamed(home + "/报告（恢复）.pdf") && (try? String(contentsOfFile: home + "/报告.pdf")) == "报告.pdf", "原位置已有同名文件：不覆盖，改名放回")
        let r3 = rec("报告.pdf")
        T.check(CleanRestore.restore(r3) == .renamed(home + "/报告（恢复 2）.pdf"), "再次冲突：继续换名")
        let r4f = rec("缓存目录")
        T.check(CleanRestore.restore(r4f) == .restored(home + "/缓存目录"), "没有扩展名的项也能恢复")
        try? fm.removeItem(atPath: home)
        let r5 = rec("日志.log")
        T.check(CleanRestore.restore(r5) == .restored(home + "/日志.log") && fm.fileExists(atPath: home + "/日志.log"), "原目录已不存在：重新创建后恢复")
        let r6 = rec("已清倒.zip", trashed: false)
        T.check(CleanRestore.status(r6) == .trashGone && CleanRestore.restore(r6).message.contains("废纸篓里已经找不到"), "废纸篓已清倒：明确说明无法恢复")
        let old = CleanRecord(date: Date(), path: home + "/旧.txt", size: 1, trashed: true)
        T.check(CleanRestore.status(old) == .untracked && CleanRestore.restore(old).message.contains("手动放回"), "旧版记录没有废纸篓位置：提示手动放回")
        let store = CleanStore(); store.recordsURL = URL(fileURLWithPath: root + "/records.json")
        let r7 = rec("安装包.dmg"); store.records = [r7]
        let n0 = ChangeLog.shared.records.count
        T.check(store.restore(r7) == .restored(home + "/安装包.dmg") && store.records[0].restored == true && store.restoreNote.hasPrefix("已恢复"), "清理页恢复后记录标为已恢复并显示结果")
        T.check(ChangeLog.shared.records.count == n0 + 1 && ChangeLog.shared.records.last?.title == "从废纸篓恢复：安装包.dmg", "恢复写入改动记录")
        store.records = [r6]
        _ = store.restore(r6)
        T.check(store.records[0].restored != true && store.restoreNote.contains("无法恢复"), "恢复失败时记录不变并显示原因")
        if ChangeLog.shared.records.count > n0 { ChangeLog.shared.records.removeLast(ChangeLog.shared.records.count - n0) }
        let oldJSON = #"[{"id":"00000000-0000-0000-0000-000000000001","date":0,"path":"/tmp/a","size":1,"trashed":true,"trashPath":"/tmp/t"}]"#
        T.check((try? JSONDecoder().decode([CleanRecord].self, from: Data(oldJSON.utf8)))?.first?.restored == nil, "2.9 的清理记录可读取")
        try? fm.removeItem(atPath: root)

        T.sec("2.10 充电助手只在已安装的位置自动核对")
        T.check(HelperCheck.autoRepairAllowed(bundlePath: "/Applications/Mac一键优化.app") && HelperCheck.autoRepairAllowed(bundlePath: "/Users/a/Applications/Mac一键优化.app"), "应用程序文件夹：照常核对")
        T.check(!HelperCheck.autoRepairAllowed(bundlePath: "/Volumes/Mac一键优化/Mac一键优化.app"), "直接从安装包里运行：不重新注册助手")
        T.check(!HelperCheck.autoRepairAllowed(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Mac一键优化.app"), "系统隔离的临时位置：不重新注册助手")
    }

    static func ui(_ w: NSWindow) {
        T.sec("2.10 桌面分区页：自定义比例")
        let c = SplitController.shared
        let suite = "mo.uitest.split210.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        let keepPrefs = c.prefs, keepDriver = c.driver, keepScreens = c.screens
        c.prefs = SplitPrefs(ud); c.driver = FakeDriver()
        c.screens = FakeScreens([SplitDisplay(uuid: "T1", name: "测试屏", visible: CGRect(x: 0, y: 0, width: 1440, height: 875), scale: 2)], 900)
        defer { c.prefs = keepPrefs; c.driver = keepDriver; c.screens = keepScreens; ud.removePersistentDomain(forName: suite); Nav.shared.sel = .monitor }
        let pv = w.contentView!
        Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .split
        T.check(T.waitUntil(2) { T.find(pv, id: "split.custom") != nil }, "模板列表里有「自定义比例」")
        T.find(pv, id: "split.tpl.121")?.press(); T.settle(0.3)
        T.find(pv, id: "split.custom")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1") == [1, 2, 1] }, "从当前模板的比例进入自定义", "\(String(describing: c.prefs.custom("T1")))")
        T.check(T.waitUntil(2) { T.find(pv, id: "split.custom.plus.1") != nil }, "出现每栏的加减按钮")
        T.find(pv, id: "split.custom.plus.1")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1") == [1, 3, 1] }, "点加号后比例立即保存")
        T.find(pv, id: "split.custom.add")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1") == [1, 3, 1, 1] }, "加一栏")
        T.find(pv, id: "split.custom.add")?.press(); T.settle(0.3)
        T.check(c.prefs.custom("T1") == [1, 3, 1, 1], "最多四栏：再点不会继续增加")
        T.find(pv, id: "split.custom.remove")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1") == [1, 3, 1] }, "减一栏")
        T.find(pv, id: "split.off")?.press()
        T.check(T.waitUntil(2) { c.prefs.weights("T1") == nil }, "关闭分区同时清掉自定义")
        T.check(T.find1(pv, id: "split.drag") != nil, "有「按住 ⇧ 拖动窗口时显示分区」开关")
    }
}
extension DragGesture.Drop: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.window.handle === b.window.handle && a.original == b.original && a.target == b.target && a.zone == b.zone }
}
