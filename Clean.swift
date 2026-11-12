// v1.8 清理与卸载
// 参考 Mole（https://github.com/tw93/Mole，GPL-3.0）只借鉴思路和路径清单，
// 没有复制它的代码：下面所有扫描、分类、进废纸篓逻辑均为本项目自写。
// 安全原则：先扫描出清单再动手；一律进废纸篓，不直接删除；默认保护系统和用户文档；
// 扫描限流（单类最多文件数、最大深度、可取消），不全盘无差别遍历。
import SwiftUI
import AppKit
import Foundation

struct CleanItem: Identifiable, Equatable {
    var id: String { path }
    var category: String
    var path: String
    var size: Int64
    var selected = false
    var isApp = false
    var bundleID = ""
}
struct CleanRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var path: String
    var size: Int64
    var trashed: Bool
    var trashPath: String? = nil
    var restored: Bool? = nil
}
enum CleanLogic {
    static let maxFilesPerRoot = 5000
    static let maxDepth = 4
    static func home() -> String { NSHomeDirectory() }
    // 默认保护：系统、应用本身、用户文档类目录一律不出现在清理清单里
    static func isProtected(_ path: String) -> Bool {
        let h = home()
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let roots = ["/System", "/Library", "/Applications/Mac一键优化.app"] + ["Documents", "Desktop", "Pictures", "Music", "Movies"].map { h + "/" + $0 }
        return p == "/" || p == h || roots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
    static func isWhitelisted(_ path: String, whitelist: [String]) -> Bool {
        whitelist.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    static func fmtSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
    // 卸载残留路径清单（按应用名和 Bundle ID 推导，不扫描全盘）
    static func leftoversFor(appName: String, bundleID: String) -> [String] {
        let h = home()
        let base = appName.replacingOccurrences(of: ".app", with: "")
        var out: [String] = []
        if !bundleID.isEmpty {
            out += [h + "/Library/Application Support/\(bundleID)", h + "/Library/Caches/\(bundleID)", h + "/Library/Preferences/\(bundleID).plist", h + "/Library/Saved Application State/\(bundleID).savedState"]
        }
        out += [h + "/Library/Application Support/\(base)", h + "/Library/Caches/\(base)", h + "/Library/Preferences/\(base).plist"]
        return Array(Set(out)).sorted()
    }
    // 扫描单个根目录：只算该目录下文件大小，限深度、限文件数、可取消（isCancelled 闭包）
    static func scanRoot(_ root: String, category: String, isCancelled: () -> Bool) -> [CleanItem] {
        var items: [CleanItem] = []
        var count = 0
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        for case let rel as String in en {
            if isCancelled() || count >= maxFilesPerRoot { break }
            let depth = rel.components(separatedBy: "/").count
            if depth > maxDepth { en.skipDescendants(); continue }
            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
            count += 1
            items.append(CleanItem(category: category, path: full, size: size))
        }
        return items
    }
    static func scanDirSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        var count = 0
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        for case let rel as String in en {
            if count >= maxFilesPerRoot { break }
            let full = (path as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                total += (try? fm.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
                count += 1
            }
        }
        return total
    }
    // 空间分析：只扫指定根、限深度、限数量，按大小倒序
    static func largeFiles(root: String, minSize: Int64, maxCount: Int, isCancelled: () -> Bool) -> [CleanItem] {
        let all = scanRoot(root, category: "大文件", isCancelled: isCancelled)
        return all.filter { $0.size >= minSize }.sorted { $0.size > $1.size }.prefix(maxCount).map { $0 }
    }
}

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
                    if CleanLogic.isProtected(full) || CleanLogic.isWhitelisted(full, whitelist: self.whitelist) { continue }
                    let size = CleanLogic.scanDirSize(full)
                    if size > 0 { found.append(CleanItem(category: cat, path: full, size: size)) }
                }
            }
            // 安装包与开发构建产物：只看下载目录和已知 DerivedData，不扫全盘
            let dl = h + "/Downloads"
            if let subs = try? FileManager.default.contentsOfDirectory(atPath: dl) {
                for sub in subs where sub.hasSuffix(".dmg") || sub.hasSuffix(".pkg") {
                    let full = (dl as NSString).appendingPathComponent(sub)
                    let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
                    if size > 0 && !CleanLogic.isWhitelisted(full, whitelist: self.whitelist) {
                        found.append(CleanItem(category: "安装包", path: full, size: size))
                    }
                }
            }
            let dd = h + "/Library/Developer/Xcode/DerivedData"
            if let subs = try? FileManager.default.contentsOfDirectory(atPath: dd) {
                for sub in subs {
                    let full = (dd as NSString).appendingPathComponent(sub)
                    let size = CleanLogic.scanDirSize(full)
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
                                         restoreNote: record.trashPath != nil ? "在「清理预览」的操作记录里点恢复" : "从废纸篓手动放回原位置")
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
    @State private var showConfirm = false
    @State private var tab = 0
    var selectedSize: Int64 { store.items.filter { $0.selected }.reduce(0) { $0 + $1.size } }
    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
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
                if tab == 1 { UninstallTab() } else {
                if !store.note.isEmpty { Text(store.note).font(.system(size: 12)).foregroundColor(store.failures.isEmpty ? DS.text.secondary : DS.text.warn).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("clean.result") }
                if !store.saveError.isEmpty {
                    StateLine(kind: .failed, text: store.saveError, id: "clean.save.error")
                    Button("重试保存") { store.saveMeta() }.buttonStyle(PillButton(filled: false)).accessibilityIdentifier("clean.save.retry")
                }
                Card(title: "清理清单", icon: "trash") {
                    if store.items.isEmpty {
                        Text(store.scanning ? "正在扫描…" : "点“开始扫描”查看缓存、日志、安装包和开发构建产物。").font(.system(size: 12)).foregroundColor(DS.text.secondary)
                        Text("“找大文件”仅查看下载目录；卸载应用和残留在「卸载应用」标签。").font(.system(size: 12)).foregroundColor(DS.text.secondary)
                    } else {
                        Text("已选 \(store.items.filter { $0.selected }.count) 项 · 共 \(CleanLogic.fmtSize(selectedSize))").font(.system(size: 12, weight: .medium))
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
                        Button(store.trashing ? "处理中…" : (store.failures.isEmpty ? "移到废纸篓（\(store.items.filter { $0.selected }.count) 项）" : "重试所选未完成项")) { showConfirm = true }.buttonStyle(PillButton()).disabled(store.items.filter { $0.selected }.isEmpty || store.trashing || store.scanning).accessibilityIdentifier("clean.trash")
                            .alert("移到废纸篓？", isPresented: $showConfirm) {
                                Button("移到废纸篓", role: .destructive) { store.trashSelected() }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("只会移到废纸篓，不会直接删除，之后还能从废纸篓恢复。")
                            }
                    }
                }
                Card(title: "白名单与操作记录", icon: "shield") {
                    HStack(spacing: 8) {
                        TextField("输入要保护的路径，点添加", text: $newWhite).textFieldStyle(.roundedBorder)
                        Button("添加白名单") { if store.addWhitelist(newWhite) { newWhite = "" } }.buttonStyle(PillButton(filled: false)).disabled(store.trashing).accessibilityIdentifier("clean.whitelist.add")
                    }
                    Text("默认保护：系统目录、/Applications 里的本应用、文稿、桌面、图片、音乐、影片").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                    if store.whitelist.isEmpty { StateLine(kind: .empty, text: "暂无自定义白名单", id: "clean.whitelist.state") }
                    ForEach(store.whitelist, id: \.self) { w in Text(w).font(.system(size: 12)).lineLimit(1) }
                    if !store.records.isEmpty {
                        Divider()
                        ForEach(store.records.suffix(10)) { r in CleanRecordRow(record: r, store: store) }
                        if !store.restoreNote.isEmpty { StateLine(kind: store.restoreNote.hasPrefix("已") ? .done : .failed, text: store.restoreNote, id: "clean.restore.state") }
                        Text("只有还在废纸篓里的项可以恢复；原位置已有同名文件时不覆盖，会改名放回。").font(.system(size: 12)).foregroundColor(DS.text.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                }
            }.padding(28)
        }
    }
}
