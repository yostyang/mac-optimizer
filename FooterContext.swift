// 2.16 N10：底栏跟随当前对象
//
// 底栏左侧说「现在选中了谁」（名称 + 类型），右侧是这个对象的主操作（具体动词）和「更多操作 ⌘K」。
// 没有选中对象时回退到当前页面的主操作；没有可执行动作就不放按钮。底栏不再重复整段页面健康状态。
// 对象身份必须稳定：进程用「进程号 + 启动时间」，应用用「进程号 + 启动时间」，记录用 UUID；执行前再次核对对象仍在。
import SwiftUI
import AppKit

/// 当前页面里被选中的对象
struct FooterObject {
    let page: Page
    let id: String               // 稳定标识（不是行号）
    let name: String
    let type: String             // 进程 / 应用 / 登录项 / 记录…
    let primary: CmdAction?      // 主操作（具体动词）；nil = 这个对象没有可执行的主操作
    var more: [CmdAction] = []
    /// 执行前核对：对象仍存在、动作仍可用；返回 nil 表示可以执行，否则是不能执行的原因
    var verify: () -> String? = { nil }
}

final class FooterContext: ObservableObject {
    static let shared = FooterContext()
    @Published private(set) var object: FooterObject?
    @Published var note = ""
    @Published var busyID: String?
    func set(_ o: FooterObject) {
        if object?.id != o.id { note = "" }
        object = o
    }
    /// 清除某页的选择；object 不属于该页时不动（切页不会误清别的页）
    func clear(page: Page, note n: String? = nil) {
        guard object?.page == page else { if let n { note = n }; return }
        object = nil; busyID = nil
        if let n { note = n }
    }
    func current(_ page: Page) -> FooterObject? { object?.page == page ? object : nil }
    /// 执行主操作：先核对，执行中同一对象不能重复触发
    func runPrimary(_ page: Page) {
        guard let o = current(page), let p = o.primary, busyID != o.id else { return }
        if let why = o.verify() { clear(page: page, note: why); return }
        busyID = o.id; note = ""
        p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.busyID == o.id { self.busyID = nil } }
    }
    /// ⌘K：选中对象的全部操作 + 当前页面与快捷操作（页面动作仍可从这里找到）
    func actionItem(_ page: Page) -> CmdItem? {
        guard let o = current(page) else { return nil }
        let ctx = ContextActions.item(page)
        var acts: [CmdAction] = []
        if let p = o.primary {
            acts.append(CmdAction(title: p.title, short: p.short, hint: "↵", destructive: p.destructive, group: o.name, run: { FooterContext.shared.runPrimary(page) }))
        }
        acts += o.more.map { a in CmdAction(title: a.title, short: a.short, hint: a.hint, destructive: a.destructive, group: o.name, run: {
            if let why = o.verify() { FooterContext.shared.clear(page: page, note: why); return }
            a.run()
        }) }
        return CmdItem(id: "obj." + o.id, kind: .action, title: o.name, subtitle: o.type, symbol: ctx.symbol, actions: acts + ctx.actions)
    }
}

/// 进程的稳定身份：进程号 + 启动时间（进程号被复用时启动时间不同）
enum ProcIdentity {
    static func key(pid: Int32, start: Date?) -> String { "proc:\(pid):" + (start.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "?") }
    static func key(_ p: ProcInfo, start: (Int32) -> Date? = ProcName.startTime) -> String { key(pid: p.id, start: start(p.id)) }
    /// 执行前核对：进程还在，并且仍是当初选中的那个（不是复用了进程号的新进程）
    static func check(_ key: String, pid: Int32, name: String, start: (Int32) -> Date? = ProcName.startTime) -> String? {
        guard let now = start(pid) else { return "「\(name)」已经退出，已取消选择" }
        return Self.key(pid: pid, start: now) == key ? nil : "「\(name)」已经退出（进程号已被其他进程使用），已取消选择，没有执行"
    }
}

// MARK: - 底栏
struct BottomBar: View {
    @ObservedObject var shell = Shell.shared
    @ObservedObject var nav = Nav.shared
    @ObservedObject var footer = FooterContext.shared
    @ObservedObject var charge = ChargeClient.shared
    var body: some View {
        HStack(spacing: 8) {
            let left = leftText
            Circle().fill(left.object ? accent : DS.text.secondary).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(left.text).font(DS.sub(left.object ? .medium : .regular)).foregroundColor(left.object ? .primary : DS.text.secondary)
                .lineLimit(1).truncationMode(.middle).contrastTarget("bottom.status").accessibilityIdentifier("bottom.status")
            if !footer.note.isEmpty && !shell.searching {
                Text(footer.note).font(DS.sub()).foregroundColor(DS.text.warn).lineLimit(1).truncationMode(.tail).accessibilityIdentifier("bottom.note")
            }
            Spacer(minLength: 8)
            if shell.searching {
                if shell.items.indices.contains(shell.sel), let p = shell.items[shell.sel].primary {
                    BarButton(title: p.title, kbd: "↵", id: "bottom.primary") { shell.runCurrent() }.help(p.title)
                }
            } else if let o = footer.current(nav.sel) {
                if let p = o.primary {
                    BarButton(title: footer.busyID == o.id ? "正在处理…" : p.title, kbd: "↵", id: "bottom.primary") { footer.runPrimary(nav.sel) }
                        .disabled(footer.busyID == o.id).help(p.title)
                }
            } else {
                // 没有选中对象：当前页面的常驻动作（最多 2 个），其余在 ⌘K 分组列表里
                ForEach(Array(ContextActions.page(nav.sel).prefix(2).enumerated()), id: \.offset) { i, a in
                    BarButton(title: a.short ?? a.title, id: "bottom.action.\(i)", run: a.run).help(a.title)
                }
            }
            BarButton(title: "更多操作", kbd: "⌘K", id: "bottom.actions") { shell.openActions() }
                .help("选中对象的全部操作、当前页面、快捷操作与前往其他页面")
        }
        .padding(.horizontal, 16).frame(height: 36)
        .background(Vibrancy(material: .headerView, solid: DS.window))
        .overlay(alignment: .top) { Hairline() }
        .onChange(of: nav.sel) { _ in footer.note = "" }
        .accessibilityElement(children: .contain).accessibilityIdentifier("bottom.bar")
    }
    var leftText: (text: String, object: Bool) {
        if shell.searching {
            guard shell.items.indices.contains(shell.sel) else { return ("没有结果 · Esc 清空搜索", false) }
            let it = shell.items[shell.sel]
            return ("\(it.title) · \(it.kind.rawValue)", true)
        }
        if let o = footer.current(nav.sel) { return ("\(o.name) · \(o.type)", true) }
        return ("\(pageTitle(nav.sel)) · 未选中对象", false)
    }
}
