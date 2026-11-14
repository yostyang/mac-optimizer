// 2.16 N8：清理与卸载记录完整浏览
//
// 「改动与提醒」的清理记录卡保留最近摘要，「查看全部」打开完整记录：现存的清理记录（clean-records.json）
// 和卸载记录（uninstall-log.json）合在一起，按类型区分，默认时间倒序、按本地日期分组。
// 只读本地已有文件，不扫描、不新增保留策略；「全部」指仍持久化存在的记录，已删掉的历史不会补造。
// 恢复沿用既有安全边界：CleanRestore.restore（不覆盖同名，改名放回）与卸载恢复（原位置已有同名就跳过）。
import SwiftUI
import AppKit

enum HistoryKind: String, CaseIterable { case clean = "清理", uninstall = "卸载" }

/// 恢复状态（显示用）
enum HistoryRestoreState: Equatable {
    case available          // 可以恢复
    case restored           // 已恢复
    case partial(String)    // 卸载记录：部分项已不能恢复（仍有可恢复项）
    case gone(String)       // 不能恢复：废纸篓里已不在 / 旧版记录没有位置 / 原位置已有同名
    var canRestore: Bool { switch self { case .available, .partial: return true; default: return false } }
    var text: String {
        switch self {
        case .available: return "可恢复"
        case .restored: return "已恢复"
        case .partial(let why), .gone(let why): return why
        }
    }
}

struct HistoryEntry: Identifiable, Equatable {
    let id: String           // 稳定标识：类型 + 记录 UUID，不用行号
    let recordID: UUID
    let kind: HistoryKind
    let date: Date
    let name: String
    let path: String         // 原路径（卸载记录取应用本体，没有时取第一项）
    let detail: String
    let state: HistoryRestoreState
}

enum RecordsHistory {
    static func entries(clean: [CleanRecord], uninstall: [UninstallRecord], fm: FileManager = .default) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for r in clean {
            let st: HistoryRestoreState
            switch CleanRestore.status(r, fm: fm) {
            case .available: st = .available
            case .restored: st = .restored
            case .trashGone: st = .gone("废纸篓里已不在")
            case .untracked: st = .gone("旧版记录没有废纸篓位置，需手动放回")
            }
            out.append(HistoryEntry(id: "clean:" + r.id.uuidString, recordID: r.id, kind: .clean, date: r.date, name: (r.path as NSString).lastPathComponent,
                                    path: r.path, detail: CleanLogic.fmtSize(r.size), state: st))
        }
        for r in uninstall {
            let main = r.entries.first { $0.original.hasSuffix(".app") } ?? r.entries.first
            out.append(HistoryEntry(id: "uninstall:" + r.id.uuidString, recordID: r.id, kind: .uninstall, date: r.date, name: r.app.isEmpty ? (main.map { ($0.original as NSString).lastPathComponent } ?? "未知应用") : r.app,
                                    path: main?.original ?? "", detail: "\(r.entries.count) 项（应用与残留）", state: uninstallState(r, fm: fm)))
        }
        return out.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }
    static func uninstallState(_ r: UninstallRecord, fm: FileManager = .default) -> HistoryRestoreState {
        if r.restored { return .restored }
        let tracked = r.entries.filter { $0.trashed != nil }
        guard !tracked.isEmpty else { return .gone("记录没有废纸篓位置，需手动放回") }
        let ok = tracked.filter { fm.fileExists(atPath: $0.trashed!) && !fm.fileExists(atPath: $0.original) }.count
        if ok == 0 { return .gone("废纸篓里已不在，或原位置已有同名") }
        return ok == r.entries.count ? .available : .partial("部分可恢复（\(ok)/\(r.entries.count) 项）")
    }
    /// 按本地日期分组，组内时间倒序；组的顺序也是倒序
    struct DayGroup: Identifiable, Equatable { let id: String; let day: Date; let title: String; let items: [HistoryEntry] }
    static func groups(_ xs: [HistoryEntry], calendar: Calendar = .current, now: Date = Date()) -> [DayGroup] {
        var order: [Date] = []; var map: [Date: [HistoryEntry]] = [:]
        for e in xs.sorted(by: { $0.date > $1.date }) {
            let d = calendar.startOfDay(for: e.date)
            if map[d] == nil { order.append(d) }
            map[d, default: []].append(e)
        }
        return order.map { d in DayGroup(id: "\(Int(d.timeIntervalSince1970))", day: d, title: dayTitle(d, calendar: calendar, now: now), items: map[d] ?? []) }
    }
    static func dayTitle(_ d: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "昨天" }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = calendar.isDate(d, equalTo: now, toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日"
        return f.string(from: d)
    }
}

// MARK: - 异步恢复（同一项执行中禁止重复，完成后原地更新）
extension CleanStore {
    func restoreAsync(_ r: CleanRecord, completion: ((CleanRestore.Outcome) -> Void)? = nil) {
        guard !restoringIDs.contains(r.id) else { return }
        restoringIDs.insert(r.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let o = CleanRestore.restore(r)
            DispatchQueue.main.async {
                self.applyRestore(r, o)
                self.restoringIDs.remove(r.id)
                completion?(o)
            }
        }
    }
}
extension Uninstaller {
    func restoreAsync(_ rec: UninstallRecord, completion: ((Int, Int) -> Void)? = nil) {
        guard !restoringIDs.contains(rec.id) else { return }
        restoringIDs.insert(rec.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, skipped) = Uninstaller.moveBack(rec)
            DispatchQueue.main.async {
                self.applyRestore(rec, ok: ok, skipped: skipped)
                self.restoringIDs.remove(rec.id)
                completion?(ok, skipped)
            }
        }
    }
}

// MARK: - 视图
struct RecordsHistoryView: View {
    @ObservedObject var clean: CleanStore
    @ObservedObject var uninstall: Uninstaller
    let close: () -> Void
    @State private var filter: HistoryKind? = nil
    @State private var note = ""
    @State private var noteOK = true
    var body: some View {
        let all = RecordsHistory.entries(clean: clean.records, uninstall: uninstall.records)
        let shown = filter.map { k in all.filter { $0.kind == k } } ?? all
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全部清理与卸载记录").font(DS.title()).contrastTarget("page.title", .largeText)
                    Text("共 \(all.count) 条现存记录（清理 \(clean.records.count) · 卸载 \(uninstall.records.count)），按日期倒序").font(DS.sub()).foregroundColor(DS.text.secondary)
                        .accessibilityIdentifier("history.count")
                }
                Spacer()
                InlineSegment(items: [("全部", 0), ("清理", 1), ("卸载", 2)], selection: Binding(
                    get: { filter == nil ? 0 : (filter == .clean ? 1 : 2) },
                    set: { filter = $0 == 0 ? nil : ($0 == 1 ? .clean : .uninstall) }))
                    .accessibilityIdentifier("history.filter")
                Button("返回") { close() }.buttonStyle(PillButton(filled: false)).keyboardShortcut(.cancelAction).accessibilityIdentifier("history.close")
            }
            if !note.isEmpty { StateLine(kind: noteOK ? .done : .failed, text: note, id: "history.restore.state") }
            if shown.isEmpty {
                StateLine(kind: .empty, text: all.isEmpty ? "还没有清理或卸载记录" : "这个类型没有记录",
                          detail: "移到废纸篓的清理项和卸载的应用会记在这里。", id: "history.state")
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(RecordsHistory.groups(shown)) { g in
                            Section(header: SectionLabel(text: g.title + " · \(g.items.count) 条").frame(maxWidth: .infinity, alignment: .leading).background(DS.window)) {
                                ForEach(g.items) { e in HistoryRow(e: e, busy: busy(e), restore: { restore(e) }) }
                            }
                        }
                    }
                }.accessibilityIdentifier("history.list")
            }
            Footnote(text: "只列出仍保存在本机的记录；能恢复的才有「恢复」按钮。原位置已有同名文件时不覆盖：清理项改名放回，卸载项跳过并说明。")
        }
        .padding(20).frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 600).background(DS.window)
    }
    func busy(_ e: HistoryEntry) -> Bool { e.kind == .clean ? clean.restoringIDs.contains(e.recordID) : uninstall.restoringIDs.contains(e.recordID) }
    func restore(_ e: HistoryEntry) {
        guard !busy(e) else { return }
        switch e.kind {
        case .clean:
            // 执行前再核对：按稳定 UUID 找回记录，状态仍然可恢复才执行
            guard let r = clean.records.first(where: { $0.id == e.recordID }), CleanRestore.status(r) == .available else {
                noteOK = false; note = "「\(e.name)」的状态已经变化，未执行恢复"; return
            }
            note = ""
            clean.restoreAsync(r) { o in
                if case .failed(let why) = o { noteOK = false; note = why } else { noteOK = true; note = o.message }
            }
        case .uninstall:
            guard let r = uninstall.records.first(where: { $0.id == e.recordID }), RecordsHistory.uninstallState(r).canRestore else {
                noteOK = false; note = "「\(e.name)」的状态已经变化，未执行恢复"; return
            }
            note = ""
            uninstall.restoreAsync(r) { ok, skipped in
                noteOK = ok > 0 && skipped == 0
                note = "\(e.name)：已恢复 \(ok) 项" + (skipped > 0 ? "；\(skipped) 项没有恢复（废纸篓里已不在，或原位置已有同名文件，未覆盖）" : "")
            }
        }
    }
}

struct HistoryRow: View {
    let e: HistoryEntry
    let busy: Bool
    let restore: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(e.date.formatted(date: .omitted, time: .shortened)).font(DS.sub()).monospacedDigit().foregroundColor(DS.text.secondary).frame(width: 46, alignment: .leading)   // 时间
            Text(e.kind.rawValue).font(DS.cap(.semibold)).foregroundColor(e.kind == .clean ? accentText : DS.text.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: DS.r.control, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(DS.sub(.medium)).lineLimit(1).truncationMode(.middle)
                Text(e.path.isEmpty ? "原路径未记录" : e.path).font(DS.cap(.regular)).foregroundColor(DS.text.secondary).lineLimit(1).truncationMode(.middle).help(e.path)
            }
            Spacer(minLength: 8)
            Text(e.detail).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1)
            Group {
                if busy {
                    HStack(spacing: 4) { ProgressView().controlSize(.small); Text("恢复中…").font(DS.sub()).foregroundColor(DS.text.secondary) }
                } else if e.state.canRestore {
                    Button("恢复") { restore() }.buttonStyle(PillButton(filled: false))
                        .accessibilityLabel("恢复 " + e.name).accessibilityIdentifier("history.restore." + e.id)
                } else {
                    Text(e.state.text).font(DS.sub()).foregroundColor(DS.text.secondary).lineLimit(1)
                }
            }.frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(e.kind.rawValue)，\(e.name)，\(e.date.formatted(date: .abbreviated, time: .shortened))，\(e.state.text)")
        .accessibilityIdentifier("history.row." + e.id)
    }
}
