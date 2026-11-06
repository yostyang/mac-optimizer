// v2.5 主窗口外壳：顶部搜索、浅色侧栏、底部操作栏、⌘K 操作面板、键盘操作、全局命令面板
// 交互模式参考 Raycast（列表 / ⌘K / 快捷键提示都是 macOS 上的通行做法），品牌与配色仍是自己的。
import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 页面清单
struct NavPage: Identifiable, Equatable {
    let id: Page; let icon: String; let title: String; let sub: String; let group: String
}

let navPages: [NavPage] = [
    NavPage(id: .overview, icon: "square.grid.2x2", title: "概览", sub: "卡不卡、为什么、怎么处理", group: "状态"),
    NavPage(id: .monitor, icon: "waveform.path.ecg.rectangle", title: "实时监控", sub: "CPU、内存、磁盘、网络", group: "状态"),
    NavPage(id: .battery, icon: "battery.75", title: "电池", sub: "健康、耗电与充电上限", group: "状态"),
    NavPage(id: .display, icon: "display", title: "显示器", sub: "亮度、场景与分辨率", group: "状态"),
    NavPage(id: .network, icon: "network", title: "网络诊断", sub: "延迟、DNS 与测速", group: "状态"),
    NavPage(id: .clean, icon: "trash", title: "清理预览", sub: "先扫描、勾选，再进废纸篓", group: "状态"),
    NavPage(id: .changes, icon: "list.clipboard", title: "改动与提醒", sub: "DNS、清理记录与异常提醒", group: "状态"),
    NavPage(id: .tool(.resources), icon: "chart.bar.xaxis", title: "资源排行", sub: "看看谁最占内存和 CPU", group: "工具"),
    NavPage(id: .tool(.startup), icon: "power", title: "开机启动", sub: "关掉不需要的开机自启", group: "工具"),
    NavPage(id: .tool(.browsers), icon: "globe", title: "浏览器", sub: "同时开太多浏览器会拖慢系统", group: "工具"),
    NavPage(id: .tool(.spotlight), icon: "magnifyingglass", title: "Spotlight", sub: "索引卡住时一键重启", group: "工具"),
    NavPage(id: .tool(.virtualMachines), icon: "shippingbox", title: "虚拟机", sub: "Claude 等应用的后台虚拟机", group: "工具"),
    NavPage(id: .tool(.vpn), icon: "shield.lefthalf.filled", title: "网络与 VPN", sub: "多个 VPN 同时运行会互相冲突", group: "工具"),
    NavPage(id: .tool(.displayPerformance), icon: "rectangle.on.rectangle", title: "显示性能", sub: "减轻大屏幕的渲染负担", group: "工具"),
    NavPage(id: .split, icon: "rectangle.split.3x1", title: "桌面分区", sub: "每块屏幕的窗口分区模板", group: "状态"),
    NavPage(id: .settings, icon: "gearshape", title: "设置", sub: "全局快捷键、菜单栏与启动", group: "设置"),
]

/// 工具页沿用旧结构（Loaders 按 id 取行）
struct Feature: Identifiable { let id: ToolKind; let icon: String; let title: String; let sub: String }
let features: [Feature] = navPages.compactMap { item in
    guard case .tool(let kind) = item.id else { return nil }
    return Feature(id: kind, icon: item.icon, title: item.title, sub: item.sub)
}

func pageTitle(_ id: Page) -> String { navPages.first { $0.id == id }?.title ?? "Mac 一键优化" }

// MARK: - 快捷操作清单（面板与搜索共用一份）
struct QuickAction: Identifiable {
    let id: String; let symbol: String; let title: String; let hint: String
    let isOn: () -> Bool
    let stateLabel: () -> String
    let run: () -> Void
}

enum QuickActionList {
    static func all() -> [QuickAction] {
        let ui = UIState.shared, ka = KeepAwake.shared, cc = ChargeClient.shared, dock = DockMode.shared
        return [
            QuickAction(id: "act.shot", symbol: "camera.viewfinder", title: "截图", hint: "⇧⌘4",
                        isOn: { false }, stateLabel: { "" }, run: { Actions.screenshot() }),
            QuickAction(id: "act.mic", symbol: ui.micMuted ? "mic.slash.fill" : "mic.fill", title: "麦克风",
                        hint: "静音", isOn: { ui.micMuted },
                        stateLabel: { ui.micMuted ? "已静音" : "正常" },
                        run: { if Mic.setMuted(!Mic.muted) { ui.micMuted = Mic.muted } }),
            QuickAction(id: "act.awake", symbol: ka.on ? "sun.max.fill" : "sun.max", title: "常亮",
                        hint: "防止息屏", isOn: { ka.on },
                        stateLabel: { ka.on ? "已开启" : "关闭" }, run: { ka.toggle() }),
            QuickAction(id: "act.clean", symbol: "sparkles.rectangle.stack", title: "擦屏", hint: "Esc 退出",
                        isOn: { false }, stateLabel: { "" }, run: { Overlay.cleanScreen() }),
            QuickAction(id: "act.charge", symbol: "battery.75", title: "充电上限",
                        hint: cc.phase == .ready ? "\(cc.st.settings.limit)%" : "需安装助手",
                        isOn: { cc.phase == .ready && cc.st.settings.enabled },
                        stateLabel: { cc.phase == .ready ? (cc.st.settings.enabled ? "上限 \(cc.st.settings.limit)%" : "关闭") : "未安装" },
                        run: {
                            if cc.phase == .ready { cc.setLimit(cc.st.settings.limit, enabled: !cc.st.settings.enabled) }
                            else { Nav.shared.sel = .battery; StatusBar.shared.popover.performClose(nil); UIState.shared.openMain() }
                        }),
            QuickAction(id: "act.dock", symbol: dock.active ? "powerplug.fill" : "powerplug", title: "接显示器",
                        hint: "息屏不断网", isOn: { dock.enabled },
                        stateLabel: { dock.status }, run: { dock.setEnabled(!dock.enabled) }),
        ]
    }
}

// MARK: - 命令项
/// 不依赖 `ps` 的进程枚举：libproc 只读接口，任何环境下都能列出本用户可见的进程
enum ProcScan {
    struct Item { let pid: Int32; let name: String; let path: String; let memMB: Double }
    static func all() -> [Item] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(0, got))).compactMap { pid in
            guard pid > 0 else { return nil }
            var pathBuf = [CChar](repeating: 0, count: 1024)
            guard proc_pidpath(pid, &pathBuf, 1024) > 0 else { return nil }
            let path = String(cString: pathBuf)
            guard !path.isEmpty else { return nil }
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, 256)
            var name = String(cString: nameBuf)
            if name.isEmpty { name = (path as NSString).lastPathComponent }
            var ti = proc_taskinfo()
            let ok = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size)
            return Item(pid: pid, name: name, path: path, memMB: ok ? Double(ti.pti_resident_size) / 1_048_576 : 0)
        }
    }
}

struct CmdAction: Identifiable {
    let id = UUID()
    let title: String
    var short: String? = nil      // 列表行右侧的短标签
    var hint: String? = nil
    var destructive = false
    let run: () -> Void
}

struct CmdItem: Identifiable {
    enum Kind: String { case page = "页面", action = "操作", process = "进程" }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var icon: NSImage? = nil
    var tint: Color = accent
    var actions: [CmdAction] = []
    var primary: CmdAction? { actions.first }
}

enum CmdIndex {
    static func pages(_ q: String) -> [CmdItem] {
        navPages.filter { matches(q, $0.title + " " + $0.sub + " " + $0.group) }.map { p in
            CmdItem(id: "page.\(p.id.storageKey)", kind: .page, title: p.title, subtitle: p.sub, symbol: p.icon,
                    actions: [CmdAction(title: "打开「\(p.title)」", short: "打开", hint: "↵", run: { open(p.id) })])
        }
    }

    static func actions(_ q: String) -> [CmdItem] {
        var out: [CmdItem] = []
        for a in QuickActionList.all() where matches(q, a.title + " " + a.hint + " " + a.stateLabel()) {
            out.append(CmdItem(id: "action.\(a.id)", kind: .action, title: a.title,
                               subtitle: a.stateLabel().isEmpty ? a.hint : a.stateLabel(),
                               symbol: a.symbol, tint: a.isOn() ? good : accent,
                               actions: [CmdAction(title: a.title, hint: "↵", run: a.run)]))
        }
        if matches(q, "体检 一键体检 扫描 检查 卡不卡") {
            out.append(CmdItem(id: "action.checkup", kind: .action, title: "一键体检", subtitle: "重新分析卡顿原因",
                               symbol: "waveform.path.ecg",
                               actions: [CmdAction(title: "开始体检", hint: "↵", run: {
                                   Nav.shared.sel = .overview; UIState.shared.openMain()
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Shell.shared.model?.scan() }
                               })]))
        }
        out += SplitController.commands(q)
        if matches(q, "设置 快捷键 全局 热键") {
            out.append(CmdItem(id: "action.settings", kind: .action, title: "设置", subtitle: "全局快捷键、菜单栏与启动",
                               symbol: "gearshape", actions: [CmdAction(title: "打开设置", hint: "↵", run: { open(.settings) })]))
        }
        return out
    }

    static func processes(_ q: String) -> [CmdItem] {
        let key = q.lowercased()
        return ProcScan.all().filter { $0.name.lowercased().contains(key) && $0.pid != getpid() }
            .sorted { $0.memMB > $1.memMB }.prefix(12).map { p in
                let fix = ProcActions.fix(for: ProcInfo(id: p.pid, name: p.name, cpu: 0, memMB: p.memMB))
                var acts: [CmdAction] = []
                if let t = fix.title {
                    acts.append(CmdAction(title: t, short: fix.short ?? "处理", hint: "↵", destructive: true, run: { FixRunner.perform(fix) }))
                }
                acts.append(CmdAction(title: "复制进程名", hint: "⌘C", run: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.name, forType: .string) }))
                acts.append(CmdAction(title: "复制 PID \(p.pid)", run: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(p.pid)", forType: .string) }))
                return CmdItem(id: "proc.\(p.pid)", kind: .process, title: p.name,
                               subtitle: String(format: "内存 %@ · PID %d", Fmt.mem(p.memMB), p.pid),
                               symbol: "gearshape", tint: Color(nsColor: .secondaryLabelColor),
                               actions: acts)
            }
    }

    static func open(_ id: Page) {
        Nav.shared.sel = id
        StatusBar.shared.popover.performClose(nil)
        UIState.shared.openMain()
    }

    static func matches(_ q: String, _ hay: String) -> Bool {
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return false }
        return hay.lowercased().contains(k)
    }
}

// MARK: - 外壳状态
final class Shell: ObservableObject {
    static let shared = Shell()
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published var items: [CmdItem] = []
    @Published var sel = 0
    @Published var actionsFor: CmdItem?
    @Published var actionQuery = ""
    @Published var actionSel = 0
    weak var model: Model?
    /// 当前页面自己的列表键盘处理（↑↓ / ↵），搜索与操作面板优先
    var listHandler: ((NSEvent) -> Bool)?
    private var procWork: DispatchWorkItem?
    private var procCache: [CmdItem] = []

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func refresh() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { items = []; sel = 0; procCache = []; return }
        let head = CmdIndex.pages(q) + CmdIndex.actions(q)
        items = head + procCache.filter { $0.title.lowercased().contains(q.lowercased()) || $0.subtitle.lowercased().contains(q.lowercased()) }
        sel = min(sel, max(0, items.count - 1))
        guard q.count >= 2 else { return }
        procWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            let found = CmdIndex.processes(q)
            DispatchQueue.main.async {
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == q else { return }
                self.procCache = found
                self.items = CmdIndex.pages(q) + CmdIndex.actions(q) + found
            }
        }
        procWork = w
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.18, execute: w)
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        sel = min(max(0, sel + d), items.count - 1)
    }

    func runCurrent() {
        guard items.indices.contains(sel), let p = items[sel].primary else { return }
        p.run()
        query = ""
        CommandPalette.shared.close()
    }

    func openActions() {
        guard items.indices.contains(sel) else {
            // 空搜索时：桌面分区页给分区操作，其它页明确提示（不再静默无响应）
            if let ctx = Self.contextItem(page: Nav.shared.sel) {
                actionQuery = ""; actionSel = 0
                withAnimation(.easeOut(duration: DS.motionFast)) { actionsFor = ctx }
            } else {
                SplitHUD.show("在顶部搜索框输入关键词（页面、操作或进程），选中后按 ⌘K 查看更多操作")
            }
            return
        }
        actionQuery = ""; actionSel = 0
        withAnimation(.easeOut(duration: DS.motionFast)) { actionsFor = items[sel] }
    }

    static func contextItem(page: Page) -> CmdItem? {
        guard page == .split else { return nil }
        let acts = SplitController.commands("分区").flatMap { $0.actions }
        return CmdItem(id: "ctx.split", kind: .action, title: "桌面分区", subtitle: "把最近使用的应用窗口放进分区",
                       symbol: "rectangle.split.3x1", actions: acts)
    }

    var filteredActions: [CmdAction] {
        guard let a = actionsFor else { return [] }
        let q = actionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? a.actions : a.actions.filter { $0.title.lowercased().contains(q) }
    }

    func runAction(_ i: Int) {
        let list = filteredActions
        guard list.indices.contains(i) else { return }
        let a = list[i]
        actionsFor = nil
        a.run()
        query = ""
    }

    /// 键盘操作：返回 true 表示已消费
    func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let typing = (e.window?.firstResponder as? NSTextView) != nil
        if actionsFor != nil {
            switch e.keyCode {
            case Key.escape: actionsFor = nil; return true                     // Esc
            case Key.down: actionSel = min(actionSel + 1, max(0, filteredActions.count - 1)); return true
            case Key.up: actionSel = max(0, actionSel - 1); return true
            case Key.enter, Key.keypadEnter: runAction(actionSel); return true
            default: return typing && !cmd ? false : false
            }
        }
        if cmd, let c = e.charactersIgnoringModifiers, c == "k" { openActions(); return true }
        if cmd, let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
            let list = navPages.filter { $0.group != "设置" }
            if list.indices.contains(n - 1) {
                Nav.shared.sel = list[n - 1].id
                UIState.shared.openMain()
                CommandPalette.shared.close()
                return true
            }
        }
        if e.keyCode == Key.escape {                                       // Esc
            if searching { query = ""; return true }
            if CommandPalette.shared.isOpen { CommandPalette.shared.close(); return true }
            return false
        }
        if searching {
            switch e.keyCode {
            case Key.down: move(1); return true
            case Key.up: move(-1); return true
            case Key.enter, Key.keypadEnter: runCurrent(); return true
            default: break
            }
        }
        if let h = listHandler, h(e) { return true }
        return false
    }
}

// MARK: - 键盘事件接入
struct KeyRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { KeyView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

final class KeyView: NSView {
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil, let w = window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window === w else { return e }
            return Shell.shared.handle(e) ? nil : e
        }
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

// MARK: - 侧栏
struct Sidebar: View {
    @Binding var sel: Page
    func item(_ p: NavPage) -> some View {
        let on = sel == p.id
        return Button { sel = p.id } label: {
            HStack(spacing: 8) {
                Image(systemName: p.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(on ? accentText : .secondary)
                    .frame(width: 16)
                Text(p.title).font(DS.body(on ? .medium : .regular))
                    .foregroundColor(on ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                .fill(on ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(Color.clear)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                IconBadge(symbol: "speedometer", tint: accent, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mac 一键优化").font(DS.body(.semibold))
                    Text("让 Mac 重新轻快").font(DS.cap()).foregroundColor(.secondary)
                }
            }.padding(.horizontal, 10).padding(.top, 46).padding(.bottom, 14)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(["状态", "工具", "设置"], id: \.self) { g in
                        if g != "状态" { SectionLabel(text: g) }
                        ForEach(navPages.filter { $0.group == g }) { item($0) }
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(DS.cap())
                Text("清理先进废纸篓").font(DS.cap())
            }.foregroundColor(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
        }
        .frame(width: 208).frame(maxHeight: .infinity, alignment: .top)
        .background(Vibrancy(material: .sidebar, solid: DS.sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(DS.separator).frame(width: 1) }
    }
}

// MARK: - 顶部搜索栏
struct TopBar: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        HStack(spacing: 8) {
            SearchField(text: $shell.query, autoFocus: false)
                .frame(maxWidth: 460)
            Spacer(minLength: 8)
            Button { shell.openActions() } label: {
                HStack(spacing: 5) { Text("操作").font(DS.sub()); Kbd(text: "⌘K") }
            }
            .buttonStyle(.plain).help("查看当前选中项的操作")
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(Vibrancy(material: .headerView, solid: DS.window))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - 底部操作栏
struct BottomBar: View {
    @ObservedObject var shell = Shell.shared
    @ObservedObject var mon = Monitor.shared
    @ObservedObject var nav = Nav.shared
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(shell.searching ? accent : good).frame(width: 6, height: 6)
            Text(status).font(DS.sub()).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            hint("主操作", "↵")
            hint("操作", "⌘K")
            hint("切换页面", "⌘1–9")
        }
        .padding(.horizontal, 16).frame(height: 34)
        .background(Vibrancy(material: .headerView, solid: DS.window))
        .overlay(alignment: .top) { Hairline() }
    }
    var status: String {
        if shell.searching { return "\(shell.items.count) 项结果 · ↑↓ 选择，↵ 执行" }
        let h = mon.s.health
        return "\(pageTitle(nav.sel)) · \(h.status) · 健康分 \(h.score)"
    }
    func hint(_ t: String, _ k: String) -> some View {
        HStack(spacing: 4) { Text(t).font(DS.cap()).foregroundColor(.secondary); Kbd(text: k) }
    }
}

// MARK: - 搜索结果
struct SearchResults: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(shell.items.enumerated()), id: \.element.id) { i, item in
                    if i == 0 || shell.items[i - 1].kind != item.kind {
                        SectionLabel(text: item.kind.rawValue)
                    }
                    ListRow(icon: item.icon, symbol: item.symbol, tint: item.tint, title: item.title,
                            subtitle: item.subtitle, selected: shell.sel == i,
                            action: { shell.sel = i; shell.runCurrent() }) {
                        if let p = item.primary {
                            HStack(spacing: 6) {
                                if let s = p.short {
                                    Text(s).font(DS.sub()).lineLimit(1)
                                        .foregroundColor(shell.sel == i ? Color.white.opacity(0.85) : .secondary)
                                }
                                Kbd(text: "↵", on: shell.sel == i)
                            }
                        }
                    }.id(item.id)
                }
                if shell.items.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "没有找到「\(shell.query)」",
                               sub: "可以试试页面名、操作名，或进程名")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }
}

// MARK: - ⌘K 操作面板
struct ActionPanel: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.16).ignoresSafeArea().onTapGesture { shell.actionsFor = nil }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    IconBadge(symbol: shell.actionsFor?.symbol ?? "bolt", tint: shell.actionsFor?.tint ?? accent, size: 18)
                    Text(shell.actionsFor?.title ?? "").font(DS.body(.medium)).lineLimit(1)
                    Spacer()
                    Kbd(text: "esc")
                }.padding(.horizontal, 10).padding(.top, 8)
                SearchField(text: $shell.actionQuery, placeholder: "搜索操作", autoFocus: true)
                    .padding(.horizontal, 8).padding(.bottom, 8)
                Hairline()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(Array(shell.filteredActions.enumerated()), id: \.element.id) { i, a in
                            HStack(spacing: 8) {
                                Text(a.title).font(DS.body(a.destructive ? .medium : .regular))
                                    .foregroundColor(a.destructive ? bad : .primary).lineLimit(1)
                                Spacer()
                                if let h = a.hint { Kbd(text: h) }
                            }
                            .padding(.horizontal, 8).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous)
                                .fill(shell.actionSel == i ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear)))
                            .foregroundColor(shell.actionSel == i ? .white : .primary)
                            .contentShape(Rectangle())
                            .onTapGesture { shell.runAction(i) }
                        }
                    }.padding(6)
                }
            }
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: DS.r.card, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        }
    }
}

// MARK: - 全局命令面板
struct CommandPaletteView: View {
    @ObservedObject var shell = Shell.shared
    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $shell.query, placeholder: "搜索页面、操作或进程，回车执行", autoFocus: true,
                        onSubmit: { shell.runCurrent() })
                .padding(10)
            Hairline()
            SearchResults(shell: shell)
            Hairline()
            HStack(spacing: 10) {
                Text("全局命令").font(DS.cap()).foregroundColor(.secondary)
                Spacer()
                Kbd(text: "↵"); Text("执行").font(DS.cap()).foregroundColor(.secondary)
                Kbd(text: "⌘K"); Text("更多操作").font(DS.cap()).foregroundColor(.secondary)
                Kbd(text: "esc"); Text("关闭").font(DS.cap()).foregroundColor(.secondary)
            }.padding(.horizontal, 12).frame(height: 30)
        }
        .frame(width: 620, height: 440)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 1))
        .overlay(alignment: .center) {
            if shell.actionsFor != nil { ActionPanel(shell: shell) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(KeyRouter())   // 全局面板自己的 ↑↓ / ↵ / Esc / ⌘K
    }
}

final class PaletteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CommandPalette: NSObject {
    static let shared = CommandPalette()
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    var isOpen: Bool { window?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let w = window ?? make()
        window = w
        Shell.shared.query = ""
        w.setContentSize(NSSize(width: 620, height: 440))
        if let s = NSScreen.main {
            let f = s.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - 310, y: f.midY - 120))
        }
        SplitController.shared.capture()   // 激活本 App 之前记下目标应用
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.contentView)
    }

    func close() { window?.orderOut(nil); Shell.shared.query = "" }

    private func make() -> NSWindow {
        let w = PaletteWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.level = .floating; w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.contentView = NSHostingView(rootView: CommandPaletteView())
        return w
    }

    // MARK: 全局热键（Carbon，不需要辅助功能权限）
    static let defCode: UInt32 = 49            // Space
    static let defMods: UInt32 = UInt32(optionKey)
    var shortcut: (code: UInt32, mods: UInt32) {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotkey.code") != nil else { return (Self.defCode, Self.defMods) }
        return (UInt32(d.integer(forKey: "hotkey.code")), UInt32(d.integer(forKey: "hotkey.mods")))
    }
    func saveShortcut(code: UInt32, mods: UInt32) {
        UserDefaults.standard.set(Int(code), forKey: "hotkey.code")
        UserDefaults.standard.set(Int(mods), forKey: "hotkey.mods")
        installHotKey()
    }
    func installHotKey() {
        if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil }
        action = { [weak self] in self?.toggle() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                CommandPalette.shared.action?()
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4D4F5054), id: 1)   // 'MOPT'
        let s = shortcut
        RegisterEventHotKey(s.code, s.mods, id, GetApplicationEventTarget(), 0, &hotKey)
    }
    static func label(code: UInt32, mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        let map: [UInt32: String] = [49: "Space", 36: "Return", 48: "Tab", 53: "Esc"]
        if let n = map[code] { s += n }
        else if let u = UnicodeScalar(code) { s += String(Character(u)) }
        return s
    }
}

// MARK: - 设置页（全局快捷键录制）
struct SettingsPage: View {
    @ObservedObject var ui = UIState.shared
    @ObservedObject var alerts = BatteryAlerts.shared
    @ObservedObject var ka = KeepAwake.shared
    @ObservedObject var dock = DockMode.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var label = CommandPalette.label(code: CommandPalette.shared.shortcut.code,
                                                   mods: CommandPalette.shared.shortcut.mods)

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "设置", sub: "全局快捷键、菜单栏与启动")
                VStack(spacing: 1) {
                    row("键盘", "command", "全局命令面板",
                        recording ? "按下新的快捷键…（需要 ⌘⌥⌃⇧ 中的至少一个）" : "在任何地方唤起搜索：接显示器、体检、关标签页") {
                        HStack(spacing: 8) {
                            Kbd(text: recording ? "…" : label)
                            Button(recording ? "取消" : "录制") { recording ? stop() : start() }
                                .buttonStyle(PillButton(filled: false))
                                .accessibilityIdentifier("set.hotkey")
                        }
                    }
                    Hairline().padding(.leading, 38)
                    row("菜单栏", "menubar.rectangle", "在菜单栏显示实时指标", "关闭后停止低频采样") {
                        Toggle("", isOn: $ui.menuBar).toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .accessibilityIdentifier("set.menubar")
                    }
                    Hairline().padding(.leading, 38)
                    row("菜单栏", "gauge", "菜单栏显示内容", "") {
                        Picker("", selection: $alerts.settings.menuIndicator) {
                            Text("CPU 占用").tag("cpu"); Text("健康分").tag("score")
                            Text("电池图标").tag("battery"); Text("网速").tag("net")
                        }.labelsHidden().frame(width: 120)
                    }
                    Hairline().padding(.leading, 38)
                    row("启动", "power", "登录时自动启动", "默认关闭") {
                        Toggle("", isOn: Binding(get: { ui.login }, set: { Actions.setLogin($0); ui.login = Actions.loginEnabled }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .accessibilityIdentifier("set.login")
                    }
                    Hairline().padding(.leading, 38)
                    row("常驻模式", "sun.max", "常亮", "临时阻止自动息屏，关闭后恢复系统默认") {
                        Toggle("", isOn: Binding(get: { ka.on }, set: { if $0 != ka.on { ka.toggle() } }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityIdentifier("set.awake")
                    }
                    Hairline().padding(.leading, 38)
                    row("常驻模式", "powerplug", "接显示器模式", "插电并连接外接屏时，息屏仍保持网络") {
                        Toggle("", isOn: Binding(get: { dock.enabled }, set: { dock.setEnabled($0) }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityIdentifier("set.dock")
                    }
                }.padding(6).card()
                VStack(spacing: 1) {
                    row("关于", "info.circle", "Mac 一键优化 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", "纯本地运行，不上传任何数据") {
                        Button("介绍页") { NSWorkspace.shared.open(URL(string: "https://yostyang.github.io/mac-optimizer/")!) }
                            .buttonStyle(PillButton(filled: false))
                    }
                    Hairline().padding(.leading, 38)
                    row("关于", "arrow.down.circle", "检查更新", "到 GitHub Releases 下载最新版") {
                        Button("打开发布页") { NSWorkspace.shared.open(URL(string: "https://github.com/yostyang/mac-optimizer/releases/latest")!) }
                            .buttonStyle(PillButton(filled: false))
                    }
                }.padding(6).card()
                HStack(spacing: 8) {
                    Button("打开菜单栏面板") { if let b = StatusBar.shared.item?.button { StatusBar.shared.show(from: b) } }
                        .buttonStyle(PillButton(filled: false))
                    Button("退出 Mac 一键优化") { NSApp.terminate(nil) }.buttonStyle(PillButton(filled: false))
                    Spacer()
                    Text("品牌紫取自 App 图标；渐变只留在健康分圆环").font(DS.cap()).foregroundColor(.secondary)
                }.padding(.top, 2)
            }.padding(20)
        }
        .onDisappear { stop() }
    }

    func row<T: View>(_ group: String, _ symbol: String, _ title: String, _ sub: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.body())
                if !sub.isEmpty { Text(sub).font(DS.cap()).foregroundColor(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }.padding(.horizontal, 8).frame(minHeight: 44)
    }

    func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !f.isEmpty else { return nil }
            var m: UInt32 = 0
            if f.contains(.command) { m |= UInt32(cmdKey) }
            if f.contains(.option) { m |= UInt32(optionKey) }
            if f.contains(.control) { m |= UInt32(controlKey) }
            if f.contains(.shift) { m |= UInt32(shiftKey) }
            CommandPalette.shared.saveShortcut(code: UInt32(e.keyCode), mods: m)
            label = CommandPalette.label(code: UInt32(e.keyCode), mods: m)
            stop()
            return nil
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
