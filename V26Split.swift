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
protocol SplitWindowDriver {
    func trusted() -> Bool
    func focusedFrame() -> CGRect?          // AX 坐标
    func setFocused(_ r: CGRect) -> CGRect? // 返回读回
}
final class AXWindowDriver: SplitWindowDriver {
    private var lastWin: AXUIElement?
    func trusted() -> Bool { AXIsProcessTrusted() }
    private func focused() -> AXUIElement? {
        guard trusted(), let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &v) == .success, let w = v else { return nil }
        return (w as! AXUIElement)
    }
    private func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?; var pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    func focusedFrame() -> CGRect? { guard let w = focused() else { return nil }; lastWin = w; return frame(w) }
    func setFocused(_ r: CGRect) -> CGRect? {
        guard let w = lastWin ?? focused() else { return nil }
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
    @Published var last: String = ""
    private(set) var undo: CGRect?   // 一步撤销（AX 坐标）

    /// 窗口中心所在显示器（AX 坐标比较）
    func display(for axFrame: CGRect) -> SplitDisplay? {
        let h = screens.primaryHeight
        let c = CGPoint(x: axFrame.midX, y: axFrame.midY)
        return screens.displays.first { SplitLayout.toAX($0.visible, primaryHeight: h).contains(c) } ?? screens.displays.first
    }

    @discardableResult
    func place(_ z: SplitZone) -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let cur = driver.focusedFrame() else { return report("没有可移动的前台窗口") }
        guard let disp = display(for: cur) else { return report("没有检测到显示器") }
        guard let t = prefs.template(disp.uuid) else { return report("这块屏幕还没选分区模板") }
        guard let r = SplitLayout.rect(t, z, in: disp.visible) else { return report("当前模板没有\(z.title)") }
        let target = SplitLayout.toAX(r, primaryHeight: screens.primaryHeight)
        let got = driver.setFocused(target)
        let o = SplitLayout.classify(target: target, actual: got)
        if o != .notMovable { undo = cur }
        return report(o.rawValue)
    }
    @discardableResult
    func undoLast() -> String {
        guard driver.trusted() else { return report("需要先授予“辅助功能”权限") }
        guard let u = undo else { return report("没有可撤销的归位") }
        guard driver.focusedFrame() != nil else { return report("没有可移动的前台窗口") }
        _ = driver.setFocused(u); undo = nil
        return report("已撤销归位")
    }
    private func report(_ s: String) -> String { DispatchQueue.main.async { self.last = s }; return s }

    static func openAXSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    static func commands(_ q: String) -> [CmdItem] {
        var out: [CmdItem] = []
        for z in [SplitZone.left, .center, .right] where CmdIndex.matches(q, "放到\(z.title) 分区 分屏 窗口 split") {
            out.append(CmdItem(id: "split.\(z.rawValue)", kind: .action, title: "放到\(z.title)", subtitle: "把前台窗口放进当前屏幕的分区",
                               symbol: "rectangle.split.3x1", actions: [CmdAction(title: "放到\(z.title)", hint: "↵", run: {
                                   StatusBar.shared.popover.performClose(nil); ToastCenter.shared.show(SplitController.shared.place(z))
                               })]))
        }
        if CmdIndex.matches(q, "撤销归位 撤销 分区 分屏 undo") {
            out.append(CmdItem(id: "split.undo", kind: .action, title: "撤销归位", subtitle: "把上次移动的窗口放回原处",
                               symbol: "arrow.uturn.backward", actions: [CmdAction(title: "撤销归位", hint: "↵", run: {
                                   ToastCenter.shared.show(SplitController.shared.undoLast())
                               })]))
        }
        return out
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
