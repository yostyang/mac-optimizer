// 清理与卸载的路径校验、扫描和数据模型；不依赖界面与系统授权。
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
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func isInside(_ path: String, root: String) -> Bool {
        let p = canonical(path), r = canonical(root)
        return p != r && p.hasPrefix(r == "/" ? r : r + "/")
    }
    // 默认保护：系统、应用本身、用户文档类目录一律不出现在清理清单里
    static func isProtected(_ path: String) -> Bool {
        let h = home()
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let roots = ["/System", "/Library", "/Applications/Mac一键优化.app"] + ["Documents", "Desktop", "Pictures", "Music", "Movies"].map { h + "/" + $0 }
        return p == "/" || p == h || p == h + "/Library" || roots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
    static func isWhitelisted(_ path: String, whitelist: [String]) -> Bool {
        let p = canonical(path)
        return whitelist.contains {
            let w = canonical($0)
            return p == w || isInside(p, root: w) || isInside(w, root: p)
        }
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
    static func scanDirSize(_ path: String, isCancelled: () -> Bool = { false }) -> Int64 {
        var total: Int64 = 0
        var count = 0
        let fm = FileManager.default
        guard !isCancelled() else { return 0 }
        var rootIsDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &rootIsDir) else { return 0 }
        if !rootIsDir.boolValue { return (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0 }
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        for case let rel as String in en {
            if isCancelled() || count >= maxFilesPerRoot { break }
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

struct UninstallItem: Identifiable, Equatable { var id: String { path }; var path: String; var kind: String; var size: Int64; var selected = true }
struct UninstallEntry: Codable, Equatable { var original: String; var trashed: String? }
struct UninstallRecord: Codable, Identifiable, Equatable { var id = UUID(); var date: Date; var app: String; var bundleID: String; var entries: [UninstallEntry]; var restored = false }
enum UninstallLogic {
    static func validBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return !value.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }
    /// 残留只能位于这些根内部；不能移动根本身，也不能通过符号链接越界。
    static func validLeftover(_ path: String, home: String) -> Bool {
        let library = URL(fileURLWithPath: home).standardizedFileURL.path + "/Library"
        let lexicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let roots = ["Application Support", "Caches", "Preferences", "Saved Application State", "Containers", "Application Scripts", "HTTPStorages", "Cookies", "WebKit", "Logs", "LaunchAgents"]
        return roots.contains { name in
            let root = library + "/" + name
            return lexicalPath.hasPrefix(root + "/") && CleanLogic.isInside(root, root: library) && CleanLogic.isInside(path, root: root)
        }
    }
    /// 返回不能卸载的原因；nil 表示可以
    static func blockReason(bundleID: String, path: String, whitelist: [String]) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        if bundleID.isEmpty { return "读不到这个应用的标识（Bundle ID），为避免误删不处理" }
        if !validBundleID(bundleID) { return "应用标识格式异常，为避免误删不处理" }
        if bundleID.hasPrefix("com.apple.") || p.hasPrefix("/System/") { return "系统自带应用，不提供卸载" }
        if bundleID == "com.yost.macoptimizer" { return "不能卸载本应用自己" }
        if CleanLogic.isWhitelisted(p, whitelist: whitelist) { return "该应用在白名单里" }
        if !p.hasSuffix(".app") { return "不是应用包" }
        return nil
    }
    /// 残留路径类别（参考 Mole 的思路自写）：只按 Bundle ID 精确匹配；应用名只用于少数常见目录且名称足够具体。
    /// 共享的 Group Containers 不默认归属某个应用，不列入。
    static func candidates(bundleID: String, name: String, home: String) -> [(String, String)] {
        guard validBundleID(bundleID) else { return [] }
        let L = home + "/Library"
        var out: [(String, String)] = [
            (L + "/Application Support/" + bundleID, "应用数据"), (L + "/Caches/" + bundleID, "缓存"),
            (L + "/Preferences/" + bundleID + ".plist", "偏好设置"), (L + "/Saved Application State/" + bundleID + ".savedState", "窗口状态"),
            (L + "/Containers/" + bundleID, "沙盒容器"), (L + "/Application Scripts/" + bundleID, "应用脚本"),
            (L + "/HTTPStorages/" + bundleID, "网络存储"), (L + "/HTTPStorages/" + bundleID + ".binarycookies", "Cookie"),
            (L + "/Cookies/" + bundleID + ".binarycookies", "Cookie"), (L + "/WebKit/" + bundleID, "网页数据"),
            (L + "/Logs/" + bundleID, "日志"), (L + "/Caches/com.crashlytics.data/" + bundleID, "崩溃数据")
        ]
        let generic: Set<String> = ["app", "apps", "helper", "update", "updater", "data", "cache", "google", "microsoft", "apple", "adobe", "mac", "macos"]
        if name.count >= 4, !name.contains("/"), !name.contains("\\"), !generic.contains(name.lowercased()) {
            out += [(L + "/Application Support/" + name, "应用数据"), (L + "/Caches/" + name, "缓存"), (L + "/Logs/" + name, "日志")]
        }
        let fm = FileManager.default
        for (dir, kind) in [(L + "/Preferences/ByHost", "偏好设置"), (L + "/LaunchAgents", "登录启动项")] {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix(bundleID + ".") && f.hasSuffix(".plist") { out.append((dir + "/" + f, kind)) }
        }
        return out.filter { validLeftover($0.0, home: home) }
    }
    static func size(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0 }
        return CleanLogic.scanDirSize(path)
    }
    static func scan(appPath: String, bundleID: String, name: String, home: String, whitelist: [String]) -> [UninstallItem] {
        guard blockReason(bundleID: bundleID, path: appPath, whitelist: whitelist) == nil else { return [] }
        var seen = Set<String>(), items: [UninstallItem] = []
        items.append(UninstallItem(path: appPath, kind: "应用本体", size: size(appPath)))
        seen.insert(appPath)
        for (p, k) in candidates(bundleID: bundleID, name: name, home: home) {
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: std), seen.insert(std).inserted else { continue }
            guard !CleanLogic.isWhitelisted(std, whitelist: whitelist) else { continue }
            items.append(UninstallItem(path: std, kind: k, size: size(std)))
        }
        return items
    }
}
