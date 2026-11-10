import AppKit
import SwiftUI
import ApplicationServices

// MARK: - 2.6 桌面分区：纯逻辑
enum SplitTemplate: String, CaseIterable, Identifiable {
    case threeCol = "121", halves = "11", twoThirds = "21"
    var id: String { rawValue }
    var title: String { switch self { case .threeCol: return "1:2:1 三栏"; case .halves: return "左右平分"; case .twoThirds: return "2/3 + 1/3" } }
    var weights: [CGFloat] { switch self { case .threeCol: return [1, 2, 1]; case .halves: return [1, 1]; case .twoThirds: return [2, 1] } }
}
enum SplitZone: Int { case left = 0, center = 1, right = 2
    var title: String { ["左区", "中区", "右区"][rawValue] }
}

enum SplitLayout {
    static let gap: CGFloat = 8
    /// 在 visibleFrame（任意坐标系）内按权重切分，外边与区间都留 gap
    static func rects(_ t: SplitTemplate, in r: CGRect, gap g: CGFloat = gap) -> [CGRect] {
        let w = t.weights, n = CGFloat(w.count)
        let avail = r.width - g * (n + 1); let total = w.reduce(0, +)
        var x = r.minX + g; var out: [CGRect] = []
        for (i, wi) in w.enumerated() {
            var width = (avail * wi / total).rounded(.down)
            if i == w.count - 1 { width = r.maxX - g - x }
            out.append(CGRect(x: x, y: r.minY + g, width: width, height: r.height - 2 * g))
            x += width + g
        }
        return out
    }
    /// 区 → 矩形；两栏模板里“中区”不存在，右区 = 最后一栏
    static func rect(_ t: SplitTemplate, _ z: SplitZone, in r: CGRect) -> CGRect? {
        let rs = rects(t, in: r)
        switch z { case .left: return rs.first; case .right: return rs.last; case .center: return rs.count == 3 ? rs[1] : nil }
    }
    /// AppKit（左下原点、y 向上，主屏为基准）→ AX（主屏左上原点、y 向下）
    static func toAX(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
    static func fromAX(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect { toAX(r, primaryHeight: h) }

    enum Outcome: String { case ok = "已归位", sizeLimited = "尺寸受应用限制", notMovable = "此窗口不可移动" }
    static func classify(target t: CGRect, actual a: CGRect?, tol: CGFloat = 2) -> Outcome {
        guard let a = a else { return .notMovable }
        let posOK = abs(a.minX - t.minX) <= tol && abs(a.minY - t.minY) <= tol
        let sizeOK = abs(a.width - t.width) <= tol && abs(a.height - t.height) <= tol
        if posOK && sizeOK { return .ok }
        if posOK || abs(a.minX - t.minX) <= 40 { return .sizeLimited }
        return .notMovable
    }
}

// MARK: - 显示器
struct SplitDisplay: Equatable { let uuid: String; let name: String; let visible: CGRect; let scale: CGFloat }
protocol SplitScreens { var displays: [SplitDisplay] { get }; var primaryHeight: CGFloat { get } }
struct SystemScreens: SplitScreens {
    var displays: [SplitDisplay] {
        NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
            return SplitDisplay(uuid: CFUUIDCreateString(nil, u) as String, name: s.localizedName,
                                visible: s.visibleFrame, scale: s.backingScaleFactor)
        }
    }
    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

// MARK: - 窗口（可注入，测试用假实现）
struct SplitTarget: Equatable { let pid: pid_t; let name: String }
/// 记录最近一次激活的“非本 App”应用（只观察通知，不轮询）
protocol SplitAppTracker { var lastExternal: SplitTarget? { get }; func reactivate(_ t: SplitTarget) }
final class SystemAppTracker: SplitAppTracker {
    private(set) var lastExternal: SplitTarget?
    private var obs: NSObjectProtocol?
    init() {
        if let a = NSWorkspace.shared.frontmostApplication { note(a) }
        obs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.note(a) }
        }
    }
    private func note(_ a: NSRunningApplication) {
        guard a.processIdentifier != getpid(), a.activationPolicy == .regular else { return }
        lastExternal = SplitTarget(pid: a.processIdentifier, name: a.localizedName ?? "前台应用")
    }
    func reactivate(_ t: SplitTarget) { NSRunningApplication(processIdentifier: t.pid)?.activate(options: []) }
}

protocol SplitWindowDriver {
    func trusted() -> Bool
    func focusedFrame(pid: pid_t) -> CGRect?  // AX 坐标；同时把该窗口设为下一次 setFocused 的对象
    var armedWindow: AnyObject? { get }       // 当前选中的具体窗口（撤销用）
    func arm(_ window: AnyObject) -> CGRect?  // 重新选中一个具体窗口；窗口已关闭返回 nil
    func setFocused(_ r: CGRect) -> CGRect? // 返回读回
}
final class AXWindowDriver: SplitWindowDriver {
    private var lastWin: AXUIElement?
    func trusted() -> Bool { AXIsProcessTrusted() }
    private func window(_ pid: pid_t) -> AXUIElement? {
        guard trusted(), pid != getpid() else { return nil }
        let a = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(a, attr as CFString, &v) == .success, let w = v, CFGetTypeID(w) == AXUIElementGetTypeID() { return (w as! AXUIElement) }
        }
        var ws: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &ws) == .success, let arr = ws as? [AXUIElement] else { return nil }
        return arr.first { w in
            var s: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &s) == .success && (s as? String) == (kAXStandardWindowSubrole as String)
        }
    }
    private func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?; var pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    var armedWindow: AnyObject? { lastWin }
    func arm(_ window: AnyObject) -> CGRect? {
        guard trusted(), CFGetTypeID(window) == AXUIElementGetTypeID() else { lastWin = nil; return nil }
        let w = window as! AXUIElement
        guard let f = frame(w) else { lastWin = nil; return nil }
        lastWin = w; return f
    }
    func focusedFrame(pid: pid_t) -> CGRect? { lastWin = nil; guard let w = window(pid) else { return nil }; lastWin = w; return frame(w) }
    func setFocused(_ r: CGRect) -> CGRect? {
        guard let w = lastWin else { return nil }
        var pt = r.origin, sz = r.size
        if let pv = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        let out = frame(w); lastWin = nil; return out
    }
}

// MARK: - 偏好（按显示器 UUID，默认关闭）
struct SplitPrefs {
    let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }
    private let key = "split.templates"
    func template(_ uuid: String) -> SplitTemplate? {
        (d.dictionary(forKey: key) as? [String: String])?[uuid].flatMap(SplitTemplate.init(rawValue:))
    }
    func set(_ t: SplitTemplate?, for uuid: String) {
        var m = (d.dictionary(forKey: key) as? [String: String]) ?? [:]
        m[uuid] = t?.rawValue; d.set(m, forKey: key)
    }
}

// MARK: - 控制器
final class SplitController: ObservableObject {
    static let shared = SplitController()
    var screens: SplitScreens = SystemScreens()
    var driver: SplitWindowDriver = AXWindowDriver()
    var prefs = SplitPrefs()
    lazy var tracker: SplitAppTracker = SystemAppTracker()
    var captured: SplitTarget?          // 打开命令面板时记下的目标应用
    func capture() { captured = tracker.lastExternal }
    @Published var last: String = ""
    private(set) var undo: CGRect?   // 一步撤销（AX 坐标）
    private var undoTarget: SplitTarget?
    private var undoWindow: AnyObject?

    /// 窗口中心所在显示器（AX 坐标比较）
    func display(for axFrame: CGRect) -> SplitDisplay? {
        let h = screens.primaryHeight
        let c = CGPoint(x: axFrame.midX, y: axFrame.midY)
        return screens.displays.first { SplitLayout.toAX($0.visible, primaryHeight: h).contains(c) } ?? screens.displays.first
    }

    @discardableResult
    func place(_ z: SplitZone) -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let tg = captured ?? tracker.lastExternal else { return report("没有找到要移动的应用窗口") }
        captured = nil
        guard let cur = driver.focusedFrame(pid: tg.pid) else { return report("「\(tg.name)」没有可移动的窗口") }
        let win = driver.armedWindow
        guard let disp = display(for: cur) else { return report("没有检测到显示器") }
        guard let t = prefs.template(disp.uuid) else { return report("这块屏幕还没选分区模板") }
        guard let r = SplitLayout.rect(t, z, in: disp.visible) else { return report("当前模板没有\(z.title)") }
        let target = SplitLayout.toAX(r, primaryHeight: screens.primaryHeight)
        let got = driver.setFocused(target)
        let o = SplitLayout.classify(target: target, actual: got)
        if o != .notMovable { undo = cur; undoTarget = tg; undoWindow = win }
        tracker.reactivate(tg)
        switch o {
        case .ok: return report("已把 \(tg.name) 放到\(z.title)")
        case .sizeLimited: return report("已把 \(tg.name) 放到\(z.title)（尺寸受应用限制）")
        case .notMovable: return report("「\(tg.name)」的窗口不可移动")
        }
    }
    @discardableResult
    func undoLast() -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let u = undo, let tg = undoTarget else { return report("没有可撤销的归位") }
        captured = nil
        // 撤销只作用于当初移动的那个具体窗口，不按应用重新取焦点窗口（同一应用多窗口时不会错移）
        guard let win = undoWindow, driver.arm(win) != nil else {
            undo = nil; undoTarget = nil; undoWindow = nil
            return report("「\(tg.name)」原来的窗口已关闭，无法撤销")
        }
        _ = driver.setFocused(u); undo = nil; undoTarget = nil; undoWindow = nil
        tracker.reactivate(tg)
        return report("已把 \(tg.name) 撤销归位")
    }
    func rememberUndo(frame: CGRect, target: SplitTarget, window: AnyObject?) { undo = frame; undoTarget = target; undoWindow = window }
    private func report(_ s: String) -> String { DispatchQueue.main.async { self.last = s }; return s }

    static func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    static func commands(_ q: String) -> [CmdItem] {
        var out: [CmdItem] = []
        for z in [SplitZone.left, .center, .right] where CmdIndex.matches(q, "放到\(z.title) 分区 分屏 窗口 split") {
            out.append(CmdItem(id: "split.\(z.rawValue)", kind: .action, title: "放到\(z.title)", subtitle: "把前台窗口放进当前屏幕的分区",
                               symbol: "rectangle.split.3x1", actions: [CmdAction(title: "放到\(z.title)", hint: "↵", run: {
                                   StatusBar.shared.popover.performClose(nil); SplitHUD.show(SplitController.shared.place(z))
                               })]))
        }
        if CmdIndex.matches(q, "撤销归位 撤销 分区 分屏 undo") {
            out.append(CmdItem(id: "split.undo", kind: .action, title: "撤销归位", subtitle: "把上次移动的窗口放回原处",
                               symbol: "arrow.uturn.backward", actions: [CmdAction(title: "撤销归位", hint: "↵", run: {
                                   SplitHUD.show(SplitController.shared.undoLast())
                               })]))
        }
        return out
    }
}

// MARK: - 结果提示：主窗口可见用 Toast，否则用不抢焦点的浮层
enum SplitHUD {
    static var panel: NSPanel?
    static var sink: ((String) -> Void)?   // 测试用
    static func show(_ text: String) {
        if let sink { sink(text); return }
        let ok = text.hasPrefix("已")
        ToastCenter.shared.show(text, symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", tint: ok ? good : .orange)
        if NSApp.windows.contains(where: { $0.isVisible && $0.isMainWindow && !($0 is NSPanel) }) { return }
        let p = panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = p
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let v = NSHostingView(rootView: Text(text).font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))).fixedSize())
        p.contentView = v; p.setContentSize(v.fittingSize)
        if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.midX - v.fittingSize.width / 2, y: f.minY + 80)) }
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { p.orderOut(nil) }
    }
}

// MARK: - 页面
struct SplitPage: View {
    @ObservedObject var c = SplitController.shared
    @State private var sel: String?
    @State private var tick = 0
    var body: some View {
        let ds = c.screens.displays
        let trusted = c.driver.trusted()
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "桌面分区", sub: "为每块屏幕选模板，再用 ⌘K 把前台窗口放进分区") { EmptyView() }
            if !trusted {
                HStack {
                    Image(systemName: "lock.shield").foregroundColor(.orange)
                    Text("需要“辅助功能”权限才能移动窗口；未授权时分区命令不可用。").font(.callout)
                    Spacer()
                    Button("打开系统设置") { SplitController.openAXSettings() }.accessibilityIdentifier("split.grant")
                }.padding(10).background(RoundedRectangle(cornerRadius: DS.r.card).fill(Color.orange.opacity(0.1)))
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 2) {
                    ForEach(ds, id: \.uuid) { d in
                        ListRow(icon: nil, symbol: "display", title: d.name,
                                subtitle: c.prefs.template(d.uuid)?.title ?? "未启用",
                                selected: (sel ?? ds.first?.uuid) == d.uuid, action: { sel = d.uuid }) { EmptyView() }.accessibilityIdentifier("split.row.\(d.uuid)")
                    }
                }.frame(width: 220).accessibilityElement(children: .contain).accessibilityIdentifier("split.list")
                if let d = ds.first(where: { $0.uuid == (sel ?? ds.first?.uuid) }) {
                    detail(d).id(tick)
                } else { Text("没有检测到显示器").foregroundColor(.secondary) }
            }
            Spacer()
        }.padding(20)
    }
    @ViewBuilder func detail(_ d: SplitDisplay) -> some View {
        let cur = c.prefs.template(d.uuid)
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "模板")
            ForEach(SplitTemplate.allCases) { t in
                Button(action: { c.prefs.set(t, for: d.uuid); tick += 1 }) {
                    HStack {
                        preview(t).frame(width: 96, height: 40)
                        Text(t.title); Spacer()
                        if cur == t { Image(systemName: "checkmark").foregroundColor(accent) }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("split.tpl.\(t.rawValue)")
            }
            Button("关闭分区") { c.prefs.set(nil, for: d.uuid); tick += 1 }
                .disabled(cur == nil).accessibilityIdentifier("split.off")
            Text(String(format: "可用区域 %.0f×%.0f pt · %.0fx", d.visible.width, d.visible.height, d.scale))
                .font(.caption).foregroundColor(.secondary)
            Divider()
            Text("把窗口放进分区").font(DS.sub(.semibold))
            Text("选好模板后，切换到要摆放的应用窗口，按 ⌘K，选择目标分区。只移动你选中的窗口，完成后可撤销。")
                .font(DS.sub()).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("split.howto")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func preview(_ t: SplitTemplate) -> some View {
        GeometryReader { g in
            ForEach(Array(SplitLayout.rects(t, in: CGRect(origin: .zero, size: g.size), gap: 3).enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.35)).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
        }.background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }
}
