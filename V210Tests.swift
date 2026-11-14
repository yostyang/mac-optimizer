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

        T.sec("2.10.1 拖动到分区：松手更宽容")
        T.check(DragGesture.shiftCounts(held: true, lastHeld: nil, now: 10), "松手时按着 ⇧：算数")
        T.check(DragGesture.shiftCounts(held: false, lastHeld: 9.8, now: 10) && DragGesture.shiftCounts(held: false, lastHeld: 9.75, now: 10), "⇧ 比鼠标早松开 0.3 秒以内：仍算数")
        T.check(!DragGesture.shiftCounts(held: false, lastHeld: 9.5, now: 10) && !DragGesture.shiftCounts(held: false, lastHeld: nil, now: 10), "⇧ 松开超过 0.3 秒或从没按过：取消")
        s = FakeDragSource()
        r = drag(s, from: CGPoint(x: 300, y: 110), to: CGPoint(x: 800, y: 400), shift: { $0 < 8 }, shiftUp: DragGesture.shiftCounts(held: false, lastHeld: 1.0, now: 1.1))
        T.check(r.0?.zone == 1, "最后一刻先松了 ⇧：高亮虽然消失，松手仍放进所在的区")
        let tz = CGRect(x: 416, y: 33, width: 800, height: 800)
        T.check(!DragGesture.needsRetry(target: tz, actual: tz) && !DragGesture.needsRetry(target: tz, actual: CGRect(x: 416, y: 33, width: 1000, height: 800)) && !DragGesture.needsRetry(target: tz, actual: nil), "位置到位（哪怕尺寸受限）或窗口已关：不重放")
        T.check(DragGesture.needsRetry(target: tz, actual: CGRect(x: 600, y: 390, width: 800, height: 600)), "位置被应用改回：需要再放一次")

        T.sec("2.10 拖动到分区：归位与撤销")
        let c = SplitController()
        let drv = FakeDriver(); c.driver = drv
        c.screens = FakeScreens([SplitDisplay(uuid: "A", name: "内建", visible: CGRect(x: 0, y: 0, width: 1632, height: 875), scale: 2)], 900)
        c.tracker = FakeTracker(SplitTarget(pid: 4242, name: "Chrome"))
        let win = FakeWin(CGRect(x: 600, y: 390, width: 800, height: 600))
        let drop = DragGesture.Drop(window: DragWindow(handle: win, pid: 4242, name: "Chrome", frame: win.frame!), original: CGRect(x: 100, y: 100, width: 800, height: 600), target: zones[1], zone: 1, down: .zero, up: .zero)
        T.check(c.placeDragged(drop) == "已把 Chrome 放到第 2 区" && win.frame == zones[1], "松手后窗口放进落区", "\(String(describing: win.frame))")
        T.check(c.undoLast() == "已把 Chrome 撤销归位" && win.frame == CGRect(x: 100, y: 100, width: 800, height: 600), "撤销回到拖动前的位置，而不是松手时的位置")
        _ = c.placeDragged(drop)
        win.frame = CGRect(x: 600, y: 390, width: 800, height: 600)   // 应用自己把窗口改回了松手时的位置
        T.check(c.replaceDragged(drop) && win.frame == zones[1] && c.undoLast() == "已把 Chrome 撤销归位" && win.frame == CGRect(x: 100, y: 100, width: 800, height: 600), "再放一次后到位，撤销位置不变")
        drv.minW = 1000
        let limited = c.placeDragged(drop)
        T.check(limited.hasSuffix("（尺寸受应用限制）") && limited.contains("不能缩到这个区这么小"), "应用有最小宽度：说明是窗口缩不到这么小", limited)
        win.frame = nil
        T.check(c.placeDragged(drop) == "「Chrome」的窗口已关闭", "窗口在松手前关闭：给出说明")
        drv.ok = false
        T.check(c.placeDragged(drop) == "需要先授予“辅助功能”权限", "没有辅助功能权限：给出说明")
        T.check(!DragZones.shared.running, "自检时不启动全局鼠标监听")

        T.sec("2.10 自定义分区比例")
        T.check(SplitCustom.valid([50, 50]) && SplitCustom.valid([30, 40, 20, 10]) && !SplitCustom.valid([100]) && !SplitCustom.valid([20, 20, 20, 20, 20]) && !SplitCustom.valid([5, 95]) && !SplitCustom.valid([50, 40]), "2 到 4 栏、每栏至少 10%、合计 100")
        T.check(SplitCustom.seed(from: [1, 2, 1]) == [25, 50, 25] && SplitCustom.seed(from: nil) == [50, 50], "从当前模板的比例开始调整（换成百分比）")
        let added = SplitCustom.addColumn([50, 50])
        T.check(added.count == 3 && SplitCustom.valid(added), "加一栏后合计仍是 100", "\(added)")
        T.check(SplitCustom.addColumn([25, 25, 25, 25]).count == 4 && SplitCustom.removeColumn([25, 50, 25]) == [33, 67] && SplitCustom.removeColumn([50, 50]) == [50, 50], "加栏减栏有上下限，减栏后按比例放大", "\(SplitCustom.removeColumn([25, 50, 25]))")
        let vf = CGRect(x: 0, y: 0, width: 1608, height: 1000)
        let r4 = SplitLayout.rects(weights: [1, 3, 3, 1], in: vf)
        T.check(r4.count == 4 && r4[0].minX == 8 && r4[3].maxX == 1600 && abs(r4[1].width - 3 * r4[0].width) <= 2, "四栏 1:3:3:1 的布局", "\(r4.map { Int($0.width) })")
        T.check(SplitLayout.rects(.threeCol, in: vf) == SplitLayout.rects(weights: [1, 2, 1], in: vf), "固定模板与同比例的自定义结果一致")
        let suite = "mo.test.split210.\(getpid())"
        let ud = UserDefaults(suiteName: suite)!; ud.removePersistentDomain(forName: suite)
        let p = SplitPrefs(ud)
        p.set(.halves, for: "A")
        T.check(p.weights("A") == [1, 1] && p.custom("A") == nil && p.title("A") == "左右平分", "老用户已选的固定模板照常生效")
        p.setCustom([30, 50, 20], for: "A")
        T.check(p.template("A") == nil && p.custom("A") == [30, 50, 20] && p.weights("A") == [30, 50, 20] && p.title("A") == "自定义 30% : 50% : 20%", "改用自定义后替换固定模板")
        p.setCustom([100], for: "A"); T.check(p.custom("A") == [30, 50, 20], "不合法的比例不保存")
        p.set(.twoThirds, for: "A"); T.check(p.custom("A") == nil && p.weights("A") == [2, 1], "选回固定模板后清掉自定义")
        p.setCustom([10, 40, 40, 10], for: "B"); p.set(nil, for: "B"); T.check(p.weights("B") == nil, "关闭分区同时清掉自定义")
        p.setCustom([12, 38, 38, 12], for: "A")
        c.prefs = p; drv.ok = true; drv.minW = 0
        let w4 = FakeWin(CGRect(x: 100, y: 100, width: 500, height: 400)); drv.focusedWin = w4
        T.check(c.place(index: 1) == "已把 Chrome 放到第 2 区" && abs(w4.frame!.minX - SplitLayout.rects(weights: [12, 38, 38, 12], in: CGRect(x: 0, y: 0, width: 1632, height: 875))[1].minX) <= 1, "四栏：按序号放到第 2 区")
        T.check(c.place(.right).hasPrefix("已把 Chrome 放到右区") && c.place(.left).hasPrefix("已把 Chrome 放到左区"), "四栏：左区 = 第一栏，右区 = 最后一栏")
        T.check(c.place(.center) == "当前模板没有中区" && c.place(index: 4) == "当前模板没有第 5 区", "四栏没有唯一的中区：给出说明")
        let shared = SplitController.shared, keepPrefs = shared.prefs, keepScreens = shared.screens
        shared.prefs = p; shared.screens = c.screens
        T.check(SplitController.commands("放到").count == 4 && SplitController.commands("放到").map(\.title) == ["放到左侧 12%", "放到左中 38%", "放到右中 38%", "放到右侧 12%"], "2.16：四栏按实际布局逐区列出，名称为空间描述", "\(SplitController.commands("放到").map(\.title))")
        p.setCustom([25, 50, 25], for: "A")
        T.check(SplitController.commands("放到").map(\.title) == ["放到左侧 1/4", "放到中间 1/2", "放到右侧 1/4"] && SplitController.commands("放到中区").count == 1, "2.16：三栏逐区列出，旧说法「中区」仍能搜到")
        // 上下平分：四栏里中间两栏各分成上下两个区（共 6 个区）
        let area = CGRect(x: 0, y: 0, width: 1632, height: 875)
        let z6 = SplitLayout.rects(weights: [1, 1, 1, 1], rows: [1, 2, 2, 1], in: area)
        T.check(z6.count == 6 && z6[0].height == 859 && z6[5].height == 859, "两侧的栏保持整栏高", "\(z6.map { Int($0.height) })")
        T.check(z6[1].minX == z6[2].minX && z6[1].width == z6[2].width && z6[1].minY > z6[2].maxY && abs(z6[1].height - z6[2].height) <= 1, "上下平分的栏：上区在前、下区在后，高度相等")
        T.check(abs(z6[1].minY - z6[2].maxY - 8) < 0.01 && z6[1].maxY == area.maxY - 8 && z6[2].minY == 8, "上下两区之间和屏幕边缘都留间距")
        T.check(SplitLayout.rects(weights: [1, 2], rows: [1, 1], in: area) == SplitLayout.rects(weights: [1, 2], in: area) && SplitLayout.rects(weights: [1, 2], rows: [], in: area).count == 2, "没有上下平分时与原来的布局一致")
        let fl = SplitLayout.rects(weights: [1, 1], rows: [2, 1], in: CGRect(x: 0, y: 0, width: 96, height: 40), gap: 3, flipped: true)
        T.check(fl.count == 3 && fl[0].minY < fl[1].minY, "预览图（y 向下）里上区画在上面")
        T.check(SplitLayout.firstZone(ofColumn: 0, rows: [1, 2, 2, 1]) == 0 && SplitLayout.firstZone(ofColumn: 2, rows: [1, 2, 2, 1]) == 3 && SplitLayout.firstZone(ofColumn: 3, rows: [1, 2, 2, 1]) == 5, "按栏找到它的第一个区")
        p.setCustom([25, 25, 25, 25], for: "A"); p.setRows([1, 2, 2, 1], for: "A")
        T.check(p.rows("A") == [1, 2, 2, 1] && p.zones("A", in: area)?.count == 6, "上下平分的设置可保存读取")
        p.setRows([1, 2], for: "A"); T.check(p.rows("A") == [1, 1, 1, 1], "栏数对不上的设置按不分处理")
        p.setRows([1, 2, 2, 1], for: "A")
        shared.prefs = p; shared.screens = c.screens
        T.check(SplitController.commands("放到").count == 6 && SplitController.commands("放到第 3 区").first?.title == "放到左中 1/4 下方", "2.16：有上下平分时逐区列出（上方 / 下方）", "\(SplitController.commands("放到").map(\.title))")
        shared.prefs = keepPrefs; shared.screens = keepScreens
        let w6 = FakeWin(CGRect(x: 100, y: 100, width: 500, height: 400)); drv.focusedWin = w6
        let ax6 = z6.map { SplitLayout.toAX($0, primaryHeight: 900) }
        T.check(c.place(index: 2) == "已把 Chrome 放到第 3 区" && w6.frame == ax6[2] && ax6[2].minY > ax6[1].minY, "按序号放到第二栏的下半区", "\(String(describing: w6.frame))")
        T.check(c.place(.right).hasPrefix("已把 Chrome 放到右区") && w6.frame == ax6[5] && c.place(.left).hasPrefix("已把") && w6.frame == ax6[0], "左区、右区仍指最左和最右的栏")
        p.setCustom([25, 50, 25], for: "A"); p.setRows([1, 2, 1], for: "A")
        let z4 = p.zones("A", in: area)!.map { SplitLayout.toAX($0, primaryHeight: 900) }
        T.check(c.place(.center).hasPrefix("已把 Chrome 放到中区") && w6.frame == z4[1] && c.place(.right).hasPrefix("已把") && w6.frame == z4[3], "中间栏上下平分时：中区指它的上半区，右区序号顺延")
        p.set(.threeCol, for: "A")
        T.check(p.rows("A") == [1, 1, 1] && p.zones("A", in: area)?.count == 3, "固定模板不受上下平分设置影响")

        T.sec("2.10 分区间距")
        T.check(p.gap == 8, "默认间距 8 pt")
        p.setGap(0)
        let g0 = p.zones("A", in: area)!
        T.check(p.gap == 0 && g0[0].minX == 0 && g0[2].maxX == 1632 && g0[0].maxX == g0[1].minX && g0[0].height == 875, "间距为 0：窗口紧贴屏幕边缘和彼此")
        p.setGap(20)
        let g20 = p.zones("A", in: area)!
        T.check(g20[0].minX == 20 && abs(g20[1].minX - g20[0].maxX - 20) < 0.01 && g20[0].minY == 20, "间距 20：边缘和栏间都是 20 pt")
        p.setGap(99); T.check(p.gap == 24, "间距上限 24 pt"); p.setGap(-5); T.check(p.gap == 0, "间距下限 0")
        p.setGap(12); _ = c.place(.left)
        T.check(w6.frame?.minX == 12 && w6.frame?.minY == 900 - 875 + 12, "归位时使用设置的间距", "\(String(describing: w6.frame))")
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

        T.sec("2.10 Keychron 键盘自报电量")
        let rep: [UInt8] = [3, 76, 0xDC, 0x2C, 0x26, 0x0A, 0x1B, 0x7F]
        T.check(KeychronHID.parse(rep) == KeychronReading(percent: 76, addresses: ["dc:2c:26:0a:1b:7f", "7f:1b:0a:26:2c:dc"]), "解析 3 号报告：电量和蓝牙地址（正倒两种字节序）")
        T.check(KeychronHID.parse([3, 76, 1, 2, 3]) == nil && KeychronHID.parse([2] + rep.dropFirst()) == nil, "长度不够或报告号不对：不采用")
        T.check(KeychronHID.parse([3, 0] + rep.dropFirst(2)) == nil && KeychronHID.parse([3, 130] + rep.dropFirst(2)) == nil, "电量不在 1–100：不采用")
        T.check(KeychronHID.parse([3, 76, 0, 0, 0, 0, 0, 0]) == nil && KeychronHID.parse([3, 76, 255, 255, 255, 255, 255, 255]) == nil, "地址全 0 或全 FF：不采用")
        func kb(_ name: String, _ addr: String, connected: Bool = true, percent: Int? = nil) -> BTDevice {
            BTDevice(name: name, address: addr, kind: "keyboard", connected: connected, ble: false, percent: percent, reason: connected ? "未取得经典蓝牙电量，可能与型号或固件有关" : "未连接")
        }
        let k3 = kb("Keychron K3 Pro", "DC-2C-26-0A-1B-7F"), mouse = kb("MX Master 2S", "AA-BB-CC-00-11-22", percent: 90)
        let reading = KeychronHID.parse(rep)!
        var merged = BTParse.apply(hid: [reading], to: [k3, mouse], access: .granted)
        T.check(merged.first { $0.name == "Keychron K3 Pro" }?.percent == 76 && merged.first { $0.name == "Keychron K3 Pro" }?.source == "键盘自报电量（HID）", "地址对得上：显示键盘自报的电量并注明来源")
        T.check(merged.first { $0.name == "MX Master 2S" }?.percent == 90, "其他设备的读数不受影响")
        let rev = KeychronHID.parse([3, 41, 0x7F, 0x1B, 0x0A, 0x26, 0x2C, 0xDC])!
        T.check(BTParse.apply(hid: [rev], to: [k3], access: .granted)[0].percent == 41, "地址字节序相反的固件也能对上")
        let other = KeychronHID.parse([3, 55, 1, 2, 3, 4, 5, 6])!
        merged = BTParse.apply(hid: [other], to: [k3], access: .granted)
        T.check(merged[0].percent == nil && merged[0].reason.contains("没有返回可核对的电量"), "地址对不上：不显示，说明原因")
        T.check(BTParse.apply(hid: [], to: [k3], access: .notAsked)[0].reason.contains("读取 Keychron 电量") && BTParse.apply(hid: [], to: [k3], access: .denied)[0].reason.contains("系统设置"), "没有权限时说明怎么开启")
        T.check(BTParse.apply(hid: [reading], to: [kb("Keychron K3 Pro", "DC-2C-26-0A-1B-7F", connected: false)], access: .granted)[0].percent == nil, "未连接的键盘不采用读数")
        T.check(!KeychronHID.candidate(mouse) && !KeychronHID.candidate(kb("Keychron K3 Pro", "x", percent: 80)) && KeychronHID.candidate(k3), "只对读不到电量的 Keychron 键盘去读")

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
        T.check(T.waitUntil(2) { c.prefs.custom("T1") == [25, 50, 25] }, "从当前模板的比例进入自定义", "\(String(describing: c.prefs.custom("T1")))")
        T.check(T.waitUntil(2) { T.find(pv, id: "split.custom.pct.1") != nil && T.find(pv, id: "split.divider.0") != nil }, "出现每栏的百分比输入框和分隔线")
        T.find(pv, id: "split.custom.add")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1")?.count == 4 && c.prefs.custom("T1")?.reduce(0, +) == 100 }, "加一栏，合计仍是 100", "\(String(describing: c.prefs.custom("T1")))")
        T.find(pv, id: "split.custom.add")?.press(); T.settle(0.3)
        T.check(c.prefs.custom("T1")?.count == 4, "最多四栏：再点不会继续增加")
        T.find(pv, id: "split.custom.remove")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1")?.count == 3 }, "减一栏")
        c.prefs.setCustom([25, 50, 25], for: "T1"); Nav.shared.sel = .monitor; T.settle(0.3); Nav.shared.sel = .split; T.settle(0.5)
        T.find(pv, id: "split.custom.rows.1")?.press()
        T.check(T.waitUntil(2) { c.prefs.rows("T1") == [1, 2, 1] }, "点图标把中间一栏上下平分")
        T.find(pv, id: "split.custom.add")?.press()
        T.check(T.waitUntil(2) { c.prefs.custom("T1")?.count == 4 && c.prefs.rows("T1") == [1, 2, 1, 1] }, "加栏时保留已有的上下平分")
        T.find(pv, id: "split.custom.rows.1")?.press()
        T.check(T.waitUntil(2) { c.prefs.rows("T1") == [1, 1, 1, 1] }, "再点一次取消上下平分")
        T.find(pv, id: "split.gap.plus")?.press()
        T.check(T.waitUntil(2) { c.prefs.gap == 10 }, "间距加 2 pt")
        T.find(pv, id: "split.gap.minus")?.press(); T.settle(0.3); T.find(pv, id: "split.gap.minus")?.press()
        T.check(T.waitUntil(2) { c.prefs.gap == 6 }, "间距可减小")
        T.find(pv, id: "split.off")?.press()
        T.check(T.waitUntil(2) { c.prefs.weights("T1") == nil }, "关闭分区同时清掉自定义")
        T.check(T.find1(pv, id: "split.drag") != nil, "有「按住 ⇧ 拖动窗口时显示分区」开关")
    }
}
extension DragGesture.Drop: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.window.handle === b.window.handle && a.original == b.original && a.target == b.target && a.zone == b.zone }
}
