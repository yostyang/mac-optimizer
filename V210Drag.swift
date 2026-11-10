// 2.10：按住 ⇧ 拖动窗口时显示分区，松手后把窗口放进所在的区（默认关闭）
//
// 做法：全局监听鼠标按下/拖动/松开。按住 ⇧ 拖动时，取鼠标下方的窗口，连续两次读它的位置：
// 尺寸不变、位置跟着鼠标走，才认定「正在拖窗口」。松手时仍按着 ⇧ 且停在某个区上，才移动窗口。
// 不碰屏幕边缘，避开 macOS 15 的系统平铺；不按 ⇧ 时不做任何辅助功能查询。
import AppKit
import ApplicationServices

struct DragWindow { let handle: AnyObject; let pid: pid_t; let name: String; let frame: CGRect }

/// 可注入：真实实现走辅助功能接口，测试用假实现
protocol DragWindowSource {
    func trusted() -> Bool
    func window(at axPoint: CGPoint) -> DragWindow?
    func frame(of handle: AnyObject) -> CGRect?
}

/// 一次拖动手势的判断（纯逻辑，坐标一律用辅助功能坐标：主屏左上为原点）
struct DragGesture {
    enum Phase: Equatable { case idle, pressed, candidate, dragging, rejected }
    struct Drop { let window: DragWindow; var original: CGRect; let target: CGRect; let zone: Int; let down: CGPoint; let up: CGPoint }
    /// 拖动时鼠标在窗口里的相对位置不变：用松手后读到的窗口位置反推拖动前的位置（不受读数延迟影响）
    static func originalFrame(down: CGPoint, up: CGPoint, frameAtUp f: CGRect) -> CGRect {
        CGRect(x: down.x - (up.x - f.minX), y: down.y - (up.y - f.minY), width: f.width, height: f.height)
    }

    static let startDistance: CGFloat = 6      // 鼠标至少移动这么远才开始判断
    static let maxTravel: CGFloat = 200        // 鼠标走了这么远窗口还没动：拖的不是窗口，放弃
    static let maxQueries = 20                 // 一次手势最多查询这么多次

    private(set) var phase: Phase = .idle
    private(set) var window: DragWindow?
    private(set) var zones: [CGRect] = []
    private(set) var active: Int?
    private(set) var queries = 0               // 本次手势做了几次辅助功能查询
    private var down = CGPoint.zero
    private var seenAt = CGPoint.zero          // 取到候选窗口时的鼠标位置
    private var original: CGRect?              // 推算出的拖动前位置（撤销用）

    mutating func mouseDown(_ p: CGPoint) { self = DragGesture(); phase = .pressed; down = p }

    /// zonesAt：给出鼠标所在屏幕的各区（没有模板返回空）
    mutating func mouseDragged(_ p: CGPoint, shift: Bool, source: DragWindowSource, zonesAt: (CGPoint) -> [CGRect]) {
        switch phase {
        case .idle, .rejected: return
        case .pressed:
            guard shift, hypot(p.x - down.x, p.y - down.y) >= Self.startDistance else { return }
            queries += 1
            guard let w = source.window(at: p) else { phase = .rejected; return }
            window = w; seenAt = p; phase = .candidate
        case .candidate:
            guard let w = window else { phase = .rejected; return }
            let dm = CGPoint(x: p.x - seenAt.x, y: p.y - seenAt.y)
            guard hypot(dm.x, dm.y) >= 3 else { return }
            queries += 1
            guard let f = source.frame(of: w.handle) else { phase = .rejected; return }
            let sameSize = abs(f.width - w.frame.width) <= 1 && abs(f.height - w.frame.height) <= 1
            let dw = CGPoint(x: f.minX - w.frame.minX, y: f.minY - w.frame.minY)
            // 窗口位置的读数会比鼠标慢一拍（实测 Chrome、Edge、Electron 都如此），所以只要求「动了、且方向与鼠标一致」
            let follows = hypot(dw.x, dw.y) >= 3 && dw.x * dm.x + dw.y * dm.y > 0
            if sameSize && follows {
                // 拖动前的位置 = 取样时的位置 − 取样前鼠标已经走过的距离
                original = w.frame.offsetBy(dx: -(seenAt.x - down.x), dy: -(seenAt.y - down.y))
                phase = .dragging; update(p, shift: shift, zonesAt: zonesAt)
            } else {
                // 尺寸在变 = 在调整大小；鼠标走远了窗口还不动 = 拖的不是窗口
                if !sameSize || hypot(dm.x, dm.y) >= Self.maxTravel || queries >= Self.maxQueries { phase = .rejected }
            }
        case .dragging:
            update(p, shift: shift, zonesAt: zonesAt)
        }
    }
    private mutating func update(_ p: CGPoint, shift: Bool, zonesAt: (CGPoint) -> [CGRect]) {
        guard shift else { zones = []; active = nil; return }
        zones = zonesAt(p); active = zones.firstIndex { $0.contains(p) }
    }

    /// 松手：仍按着 ⇧ 且停在某个区上才给出落点
    mutating func mouseUp(_ p: CGPoint, shift: Bool, zonesAt: (CGPoint) -> [CGRect]) -> Drop? {
        defer { let q = queries; self = DragGesture(); queries = q }
        guard phase == .dragging, let w = window, let o = original else { return nil }
        update(p, shift: shift, zonesAt: zonesAt)
        guard let i = active else { return nil }
        return Drop(window: w, original: o, target: zones[i], zone: i, down: down, up: p)
    }
}

// MARK: - 系统实现
struct AXDragSource: DragWindowSource {
    func trusted() -> Bool { AXIsProcessTrusted() }
    func window(at p: CGPoint) -> DragWindow? {
        guard trusted() else { return nil }
        var el: AXUIElement?
        var win: AXUIElement? = nil
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success, let e = el {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == (kAXWindowRole as String) { win = e }
            else {
                var w: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &w) == .success, let w, CFGetTypeID(w) == AXUIElementGetTypeID() { win = (w as! AXUIElement) }
            }
        }
        // 有些应用（如微信）按坐标取不到元素：改用窗口列表找到鼠标下最上层的窗口，再到该应用里按位置匹配
        if win == nil { win = Self.windowByList(at: p) }
        guard let win, let f = Self.frame(win) else { return nil }
        var pid: pid_t = 0; AXUIElementGetPid(win, &pid)
        guard pid != getpid() else { return nil }
        var sub: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &sub) == .success, (sub as? String) == (kAXStandardWindowSubrole as String) else { return nil }
        var fs: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fs) == .success, (fs as? Bool) == true { return nil }
        return DragWindow(handle: win, pid: pid, name: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "窗口", frame: f)
    }
    static func windowByList(at p: CGPoint) -> AXUIElement? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0, let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.contains(p) else { continue }
            var ws: CFTypeRef?
            guard pid != getpid(), AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &ws) == .success,
                  let arr = ws as? [AXUIElement] else { return nil }
            return arr.first { w in frame(w).map { abs($0.minX - r.minX) <= 2 && abs($0.minY - r.minY) <= 2 && abs($0.width - r.width) <= 2 } ?? false }
        }
        return nil
    }
    func frame(of handle: AnyObject) -> CGRect? {
        guard CFGetTypeID(handle) == AXUIElementGetTypeID() else { return nil }
        return Self.frame(handle as! AXUIElement)
    }
    static func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?; var pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}

/// 分区高亮浮层：不接收鼠标、不抢焦点
final class DragOverlay {
    private var panel: NSPanel?
    private var shown: ([CGRect], Int?) = ([], nil)
    /// zones 为 AppKit 坐标
    func show(zones: [CGRect], active: Int?) {
        guard !zones.isEmpty else { hide(); return }
        if shown.0 == zones && shown.1 == active && panel?.isVisible == true { return }
        shown = (zones, active)
        let union = zones.reduce(zones[0]) { $0.union($1) }
        let p = panel ?? {
            let p = NSPanel(contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let v = NSView(); v.wantsLayer = true; p.contentView = v
            return p
        }()
        panel = p
        p.setFrame(union, display: false)
        let root = p.contentView!.layer!
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let tint = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, z) in zones.enumerated() {
            let l = CALayer()
            l.frame = z.offsetBy(dx: -union.minX, dy: -union.minY)
            l.cornerRadius = 10; l.borderWidth = i == active ? 2 : 1
            l.borderColor = tint.withAlphaComponent(i == active ? 0.9 : 0.35).cgColor
            l.backgroundColor = tint.withAlphaComponent(i == active ? 0.28 : 0.08).cgColor
            root.addSublayer(l)
        }
        CATransaction.commit()
        p.orderFrontRegardless()
    }
    func hide() { shown = ([], nil); panel?.orderOut(nil) }
}

final class DragZones {
    static let shared = DragZones()
    static let prefKey = "split.dragZones"
    var source: DragWindowSource = AXDragSource()
    private var gesture = DragGesture()
    private var monitor: Any?
    private let overlay = DragOverlay()
    private var lastSample: TimeInterval = 0
    var log: ((String) -> Void)?
    private(set) var handlerSeconds: Double = 0   // 累计处理耗时（验证性能用）
    private(set) var events = 0

    var running: Bool { monitor != nil }
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in self?.handle(e) }
        log?("开始监听；辅助功能权限 \(source.trusted() ? "已授予" : "未授予")；系统 \(ProcessInfo.processInfo.operatingSystemVersionString)；系统边缘平铺 \(Self.systemEdgeTiling())")
    }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; overlay.hide(); gesture = DragGesture()
        log?("停止监听；共处理 \(events) 个事件，累计耗时 \(String(format: "%.1f", handlerSeconds * 1000)) 毫秒")
    }
    /// macOS 15 起「拖到屏幕边缘平铺」的系统设置；读不到说明系统没有这个功能或用默认值
    static func systemEdgeTiling() -> String {
        guard let v = UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool else { return "未设置（默认值）" }
        return v ? "开" : "关"
    }

    private func axPoint() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: SplitController.shared.screens.primaryHeight - m.y)
    }
    private func zones(at p: CGPoint) -> [CGRect] {
        let c = SplitController.shared, h = c.screens.primaryHeight
        guard let d = c.screens.displays.first(where: { SplitLayout.toAX($0.visible, primaryHeight: h).contains(p) }),
              let t = c.prefs.template(d.uuid) else { return [] }
        return SplitLayout.rects(t, in: d.visible).map { SplitLayout.toAX($0, primaryHeight: h) }
    }

    private func handle(_ e: NSEvent) {
        let t0 = CFAbsoluteTimeGetCurrent(); defer { handlerSeconds += CFAbsoluteTimeGetCurrent() - t0; events += 1 }
        let shift = NSEvent.modifierFlags.contains(.shift)
        switch e.type {
        case .leftMouseDown:
            gesture.mouseDown(axPoint())
        case .leftMouseDragged:
            // 没按 ⇧ 且没有进行中的窗口拖动：直接返回，不做任何查询
            guard shift || gesture.phase == .dragging else { return }
            guard e.timestamp - lastSample >= 1.0 / 30 else { return }   // 最多每秒 30 次
            lastSample = e.timestamp
            let before = gesture.phase
            gesture.mouseDragged(axPoint(), shift: shift, source: source, zonesAt: zones(at:))
            if before != gesture.phase { log?("手势：\(before) → \(gesture.phase)\(gesture.window.map { "（\($0.name)）" } ?? "")，查询 \(gesture.queries) 次") }
            let h = SplitController.shared.screens.primaryHeight
            overlay.show(zones: gesture.zones.map { SplitLayout.fromAX($0, primaryHeight: h) }, active: gesture.active)
        case .leftMouseUp:
            let q = gesture.queries
            let drop = gesture.mouseUp(axPoint(), shift: shift, zonesAt: zones(at:))
            overlay.hide()
            guard let d = drop else { if q > 0 { log?("松手：没有落区（查询 \(q) 次）") }; return }
            // 等应用自己处理完松手，再移动窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                var d = d
                if let f = self?.source.frame(of: d.window.handle) { d.original = DragGesture.originalFrame(down: d.down, up: d.up, frameAtUp: f) }
                let msg = SplitController.shared.placeDragged(d)
                self?.log?("松手：\(d.window.name) → 第 \(d.zone + 1) 区，结果「\(msg)」，撤销位置 \(Int(d.original.minX)),\(Int(d.original.minY))（查询 \(q) 次）")
                SplitHUD.show(msg)
            }
        default: break
        }
    }
}

extension SplitController {
    /// 把拖动中的窗口放进落区；撤销回到拖动前的位置
    func placeDragged(_ d: DragGesture.Drop) -> String {
        guard driver.trusted() else { return "需要先授予“辅助功能”权限" }
        guard driver.arm(d.window.handle) != nil else { return "「\(d.window.name)」的窗口已关闭" }
        let got = driver.setFocused(d.target)
        let o = SplitLayout.classify(target: d.target, actual: got)
        if o != .notMovable { rememberUndo(frame: d.original, target: SplitTarget(pid: d.window.pid, name: d.window.name), window: d.window.handle) }
        let zone = "第 \(d.zone + 1) 区"
        switch o {
        case .ok: return "已把 \(d.window.name) 放到\(zone)"
        case .sizeLimited: return "已把 \(d.window.name) 放到\(zone)（尺寸受应用限制）"
        case .notMovable: return "「\(d.window.name)」的窗口不可移动"
        }
    }
}
