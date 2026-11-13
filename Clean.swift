// v1.8 清理与卸载
// 参考 Mole（https://github.com/tw93/Mole，GPL-3.0）只借鉴思路和路径清单，
// 没有复制它的代码：下面所有扫描、分类、进废纸篓逻辑均为本项目自写。
// 安全原则：先扫描出清单再动手；一律进废纸篓，不直接删除；默认保护系统和用户文档；
// 扫描限流（单类最多文件数、最大深度、可取消），不全盘无差别遍历。
import SwiftUI
import AppKit
import Foundation

final class CleanStore: ObservableObject {
    static let shared = CleanStore()
    @Published var items: [CleanItem] = []
    @Published var scanning = false
    @Published var cancelled = false
    @Published var whitelist: [String] = []
    @Published var records: [CleanRecord] = []
    @Published var note = ""
    @Published var saveError = ""
    @Published var trashing = false
    @Published var failures: [String: String] = [:]
    @Published var restoreNote = ""
    var moveToTrash: (URL) throws -> URL? = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
    var whitelistURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/clean-whitelist.json")
    var recordsURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacOptimizer/clean-records.json")
    init() {
        if let d = try? Data(contentsOf: whitelistURL), let v = try? JSONDecoder().decode([String].self, from: d) { whitelist = v }
        if let d = try? Data(contentsOf: recordsURL), let v = try? JSONDecoder().decode([CleanRecord].self, from: d) { records = v }
    }
    @discardableResult func saveWhitelist(force: Bool = false) -> Bool {
        if MOTests.active && !force { return true }
        do {
            try FileManager.default.createDirectory(at: whitelistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(whitelist).write(to: whitelistURL, options: .atomic)
            saveError = ""
            return true
        } catch {
            saveError = "白名单未保存：\(error.localizedDescription)"
            return false
        }
    }
    @discardableResult func saveRecords(force: Bool = false) -> Bool {
        if MOTests.active && !force { return true }
        do {
            try FileManager.default.createDirectory(at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: recordsURL, options: .atomic)
            saveError = ""
            return true
        } catch {
            saveError = "清理记录未保存：\(error.localizedDescription)"
            return false
        }
    }
    @discardableResult func saveMeta(force: Bool = false) -> Bool {
        let whitelistSaved = saveWhitelist(force: force)
        let whitelistError = saveError
        let recordsSaved = saveRecords(force: force)
        if !whitelistSaved { saveError = whitelistError }
        return whitelistSaved && recordsSaved
    }
    func scan() {
        guard !scanning, !trashing else { return }
        failures = [:]
        scanning = true; cancelled = false; note = ""
        let whitelist = self.whitelist
        DispatchQueue.global(qos: .userInitiated).async {
            let h = NSHomeDirectory()
            let roots: [(String, String)] = [
                (h + "/Library/Caches", "缓存"),
                (h + "/Library/Logs", "日志"),
                (h + "/Library/Caches/com.apple.Safari", "缓存"),
            ]
            var found: [CleanItem] = []
            for (root, cat) in roots {
                if self.cancelled { break }
                // 只汇总目录级条目，不把缓存里几万个小文件全列出来：目录大小用 scanDirSize 算
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
                let subs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                for sub in subs.prefix(200) {
                    if self.cancelled { break }
                    let full = (root as NSString).appendingPathComponent(sub)
                    if CleanLogic.isProtected(full) || CleanLogic.isWhitelisted(full, whitelist: whitelist) { continue }
                    let size = CleanLogic.scanDirSize(full, isCancelled: { self.cancelled })
                    if size > 0 { found.append(CleanItem(category: cat, path: full, size: size)) }
                }
            }
            // 安装包与开发构建产物：只看下载目录和已知 DerivedData，不扫全盘
            let dl = h + "/Downloads"
            if !self.cancelled, let subs = try? FileManager.default.contentsOfDirectory(atPath: dl) {
                for sub in subs where sub.hasSuffix(".dmg") || sub.hasSuffix(".pkg") {
                    if self.cancelled { break }
                    let full = (dl as NSString).appendingPathComponent(sub)
                    let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
                    if size > 0 && !CleanLogic.isWhitelisted(full, whitelist: whitelist) {
                        found.append(CleanItem(category: "安装包", path: full, size: size))
                    }
                }
            }
            let dd = h + "/Library/Developer/Xcode/DerivedData"
            if !self.cancelled, let subs = try? FileManager.default.contentsOfDirectory(atPath: dd) {
                for sub in subs {
                    if self.cancelled { break }
                    let full = (dd as NSString).appendingPathComponent(sub)
                    if CleanLogic.isProtected(full) || CleanLogic.isWhitelisted(full, whitelist: whitelist) { continue }
                    let size = CleanLogic.scanDirSize(full, isCancelled: { self.cancelled })
                    if size > 0 { found.append(CleanItem(category: "开发构建产物", path: full, size: size)) }
                }
            }
            found.sort { $0.size > $1.size }
            DispatchQueue.main.async { self.items = found; self.scanning = false; self.note = found.isEmpty ? "没有扫到可清理项" : "已扫到 \(found.count) 项，勾选后点“移到废纸篓”才会动" }
        }
    }
    func scanLargeFiles() {
        guard !scanning, !trashing else { return }
        failures = [:]
        scanning = true; cancelled = false
        DispatchQueue.global().async {
            let found = CleanLogic.largeFiles(root: NSHomeDirectory() + "/Downloads", minSize: 100 * 1_048_576, maxCount: 50, isCancelled: { self.cancelled })
            let filtered = found.filter { !CleanLogic.isProtected($0.path) && !CleanLogic.isWhitelisted($0.path, whitelist: self.whitelist) }
            DispatchQueue.main.async { self.items = filtered; self.scanning = false; self.note = "大文件只扫了下载目录（限深度、限 50 项），不是全盘遍历" }
        }
    }
    func trashSelected() {
        guard !trashing, !scanning else { return }
        var seen = Set<String>()
        let selected = items.filter { $0.selected && seen.insert($0.path).inserted }
        guard !selected.isEmpty else { note = "请先勾选要清理的项"; return }
        trashing = true; failures = [:]; note = "正在移到废纸篓…"
        let whitelist = self.whitelist, move = moveToTrash
        DispatchQueue.global(qos: .userInitiated).async {
            var completed: [CleanRecord] = [], errors: [String: String] = [:]
            for (index, item) in selected.enumerated() {
                let canonical = URL(fileURLWithPath: item.path).standardizedFileURL.resolvingSymlinksInPath().path
                if CleanLogic.isProtected(item.path) || CleanLogic.isWhitelisted(item.path, whitelist: whitelist) || CleanLogic.isWhitelisted(canonical, whitelist: whitelist) {
                    errors[item.path] = "已受保护或加入白名单，未移动"
                } else {
                    do {
                        let destination = try move(URL(fileURLWithPath: item.path))
                        completed.append(CleanRecord(date: Date(), path: item.path, size: item.size, trashed: true, trashPath: destination?.path))
                    } catch { errors[item.path] = error.localizedDescription }
                }
                DispatchQueue.main.async { self.note = "正在处理 \(index + 1)/\(selected.count) 项…" }
            }
            DispatchQueue.main.async {
                let paths = Set(completed.map(\.path))
                self.items.removeAll { paths.contains($0.path) }
                self.failures = errors; self.records += completed
                for record in completed {
                    ChangeLog.shared.add(kind: .clean, title: "清理到废纸篓：" + (record.path as NSString).lastPathComponent,
                                         detail: record.path + "（" + CleanLogic.fmtSize(record.size) + "）", reversible: record.trashPath != nil,
                                         restoreNote: record.trashPath != nil ? CleanRecordsCard.restoreHint : "从废纸篓手动放回原位置")
                }
                self.note = "已移到废纸篓 \(completed.count) 项" + (errors.isEmpty ? "，可从废纸篓放回" : "；\(errors.count) 项未完成，已保留，可检查后重试")
                self.trashing = false; self.saveRecords()
            }
        }
    }
    @discardableResult func addWhitelist(_ path: String) -> Bool {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { note = "请输入完整路径，或以 ~/ 开头的路径"; return false }
        let p = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        guard !whitelist.contains(p) else { note = "这个路径已在白名单中"; return false }
        whitelist.append(p)
        guard saveWhitelist() else { whitelist.removeLast(); note = "白名单未保存，请重试"; return false }
        note = "已加入白名单"; return true
    }

}

struct CleanPage: View {
    @ObservedObject var store = CleanStore.shared
    @State private var newWhite = ""
    @State private var tab = 0
    var body: some View {
        // 2.14：标题与扫描按钮固定在顶部，清单局部滚动，底栏固定显示已选汇总和主按钮；清理记录与恢复在「改动与提醒」
        PageScaffold(spacing: 14, padding: 28) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("清理预览").font(DS.title())
                    Text("先扫描出清单，勾选后才动；一律进废纸篓，不直接删除").font(.system(size: 12)).foregroundColor(DS.text.secondary)
                }
                Spacer()
                SegmentedTrack {
                    Button("清理") { tab = 0 }.buttonStyle(PillButton(filled: tab == 0)).accessibilityIdentifier("clean.tab.0")
                    Button("卸载应用") { tab = 1 }.buttonStyle(PillButton(filled: tab == 1)).accessibilityIdentifier("clean.tab.1")
                }
                if tab == 0 {
                Button(store.scanning ? "扫描中…" : "开始扫描") { store.scan() }.buttonStyle(PillButton()).disabled(store.scanning || store.trashing).accessibilityIdentifier("clean.scan")
                Button("找大文件") { store.scanLargeFiles() }.buttonStyle(PillButton(filled: false)).disabled(store.scanning || store.trashing).accessibilityIdentifier("clean.large")
                if store.scanning { Button("取消") { store.cancelled = true }.buttonStyle(PillButton(filled: false)) }
                }
            }
        } details: {
            VStack(alignment: .leading, spacing: 14) {
                if tab == 1 { UninstallTab() } else {
                if !store.saveError.isEmpty {
                    StateLine(kind: .failed, text: store.saveError, actions: [.retry { store.saveMeta() }], id: "clean.save.error")
                }
                Card(title: "清理清单", icon: "trash") {
                    if store.items.isEmpty {
                        if store.scanning { StateLine(kind: .loading, text: "正在扫描缓存、日志、安装包和开发构建产物", id: "clean.state") }
                        else {
                            StateLine(kind: store.note.hasPrefix("已移到") ? .done : .empty, text: store.note.isEmpty ? "还没有扫描" : store.note, detail: "点“开始扫描”查看缓存、日志、安装包和开发构建产物；“找大文件”仅查看下载目录；卸载应用和残留在「卸载应用」标签。", id: "clean.state")
                        }
                    } else {
                        ForEach(store.items.indices, id: \.self) { i in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $store.items[i].selected).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(store.trashing)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text((store.items[i].path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(store.items[i].path).font(.system(size: 12)).foregroundColor(DS.text.secondary).lineLimit(1)
                                    if let error = store.failures[store.items[i].path] { Text(error).font(.system(size: 12)).foregroundColor(DS.text.warn).lineLimit(2) }
                                }
                                Spacer()
                                Text(store.items[i].category).font(.system(size: 12)).foregroundColor(DS.text.secondary)
                                Text(CleanLogic.fmtSize(store.items[i].size)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                }
                Card(title: "白名单", icon: "shield") {
                    HStack(spacing: 8) {
                        TextField("输入要保护的路径，点添加", text: $newWhite).textFieldStyle(.roundedBorder)
                        Button("添加白名单") { if store.addWhitelist(newWhite) { newWhite = "" } }.buttonStyle(PillButton(filled: false)).disabled(store.trashing).accessibilityIdentifier("clean.whitelist.add")
                    }
                    Text("默认保护：系统目录、/Applications 里的本应用、文稿、桌面、图片、音乐、影片").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                    if store.whitelist.isEmpty { StateLine(kind: .empty, text: "暂无自定义白名单", id: "clean.whitelist.state") }
                    ForEach(store.whitelist, id: \.self) { w in Text(w).font(.system(size: 12)).lineLimit(1) }
                }
                if !store.records.isEmpty {
                    Button { Nav.shared.sel = .changes } label: { Label("清理记录与恢复在「改动与提醒」（\(store.records.count) 条）", systemImage: "arrow.right.circle") }
                        .buttonStyle(.plain).font(DS.sub(.medium)).foregroundColor(accentText).accessibilityIdentifier("clean.records.link")
                }
                }
            }
        } footer: {
            if tab == 0 && (!store.items.isEmpty || store.trashing) { CleanFooter(store: store) }
        }
    }
}
