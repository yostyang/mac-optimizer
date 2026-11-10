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
    }
}
extension DragGesture.Drop: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.window.handle === b.window.handle && a.original == b.original && a.target == b.target && a.zone == b.zone }
}
