import Foundation

/// 只使用临时文件和模拟命令；可独立运行，也接入应用自检。
enum SafetyCoreTests {
    final class Runner: CommandRunner {
        var dns = ["Wi-Fi": ["192.0.2.53"], "Ethernet": [String]()]
        var disabled = Set<String>()
        var readCode: Int32 = 0
        var listCode: Int32 = 0
        var badOutput: String?
        var failedWrites = Set<String>()
        var ignoreWrites = false
        var writes: [[String]] = []
        func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
            switch args.first {
            case "-listnetworkserviceorder":
                return (listCode, dns.keys.sorted().enumerated().map { i, name in
                    "(\(disabled.contains(name) ? "*" : String(i + 1))) \(name)\n(Hardware Port: \(name), Device: en\(i))"
                }.joined(separator: "\n"))
            case "getifaddr": return (0, "192.0.2.1")
            case "-getdnsservers":
                let name = args[1], values = dns[args[1]] ?? []
                return (readCode, badOutput ?? (values.isEmpty ? "There aren't any DNS Servers set on \(name).\n" : values.joined(separator: "\n")))
            case "-setdnsservers":
                writes.append(args)
                if failedWrites.contains(args[1]) { return (1, "") }
                if !ignoreWrites { dns[args[1]] = args[2] == "Empty" ? [] : Array(args.dropFirst(2)) }
                return (0, "")
            default: return (0, "")
            }
        }
    }

    static func run(_ check: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mo-safety-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let library = home + "/Library", caches = library + "/Caches"
        try fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: library + "/Application Support", withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Demo.app").path
        check(UninstallLogic.validBundleID("com.example.Demo-App"), "正常 Bundle ID 可用")
        for bid in ["..", "../Documents", "com..app", "/tmp/app", "com.test/app", "com.test\\app", ""] {
            check(UninstallLogic.blockReason(bundleID: bid, path: app, whitelist: []) != nil && UninstallLogic.candidates(bundleID: bid, name: "Demo", home: home).isEmpty,
                  "拒绝异常应用标识：" + bid)
        }
        check(UninstallLogic.scan(appPath: app, bundleID: "..", name: "Demo", home: home, whitelist: []).isEmpty, "异常标识不会列出卸载项")
        check(UninstallLogic.validLeftover(caches + "/com.example.app", home: home), "允许精确根内的残留")
        for path in [library, caches, home + "/Documents/file", caches + "/../..", library + "/Caches-other/file"] {
            check(!UninstallLogic.validLeftover(path, home: home), "拒绝根目录或越界路径：" + path)
        }
        check(CleanLogic.isProtected(CleanLogic.home() + "/Library"), "用户 Library 根受保护")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = caches + "/com.example.link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: outside.path)
        check(!UninstallLogic.validLeftover(link, home: home), "拒绝指向根外的符号链接")
        try fm.removeItem(atPath: link)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: library + "/Application Support")
        check(!UninstallLogic.validLeftover(link, home: home), "不能借符号链接改用另一残留根")
        try fm.removeItem(atPath: link)
        let movedRootHome = root.appendingPathComponent("redirected").path
        try fm.createDirectory(atPath: movedRootHome + "/Library", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: movedRootHome + "/Library/Caches", withDestinationPath: outside.path)
        check(!UninstallLogic.validLeftover(movedRootHome + "/Library/Caches/app", home: movedRootHome), "残留根本身重定向到 Library 外时拒绝")

        let parent = caches + "/App", protected = parent + "/keep"
        try fm.createDirectory(atPath: protected, withIntermediateDirectories: true)
        check(CleanLogic.isWhitelisted(parent, whitelist: [protected]), "白名单子目录保护父目录整项移动")
        check(CleanLogic.isWhitelisted(protected + "/file", whitelist: [protected]), "白名单仍保护子项")
        check(CleanLogic.isWhitelisted(parent + "/other/../keep", whitelist: [protected]), "白名单标准化路径")
        check(!CleanLogic.isWhitelisted(parent + "Other", whitelist: [protected]), "白名单不误伤同前缀的兄弟目录")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: parent)
        check(CleanLogic.isWhitelisted(link, whitelist: [protected]), "白名单覆盖符号链接别名")

        let log = root.appendingPathComponent("example.log")
        try Data(repeating: 1, count: 4096).write(to: log)
        check(CleanLogic.scanDirSize(log.path) == 4096, "普通日志文件统计真实大小")
        check(CleanLogic.scanDirSize(root.appendingPathComponent("missing").path) == 0, "消失的文件不会导致扫描失败")
        check(CleanLogic.scanDirSize(log.path, isCancelled: { true }) == 0, "扫描单文件也响应取消")
        check(CleanLogic.scanDirSize(root.path, isCancelled: { true }) == 0, "目录遍历开始前响应取消")

        let backup = root.appendingPathComponent("dns.json")
        func fixture() -> (Runner, DNSFixer) {
            let runner = Runner()
            return (runner, DNSFixer(runner: runner, backupURL: backup))
        }
        for (code, output) in [(Int32(124), ""), (Int32(0), ""), (Int32(0), "192.0.2.53\nerror")] {
            let (r, f) = fixture(); r.readCode = code; r.badOutput = output
            check(!f.setAli().0 && r.writes.isEmpty && !fm.fileExists(atPath: backup.path), "DNS 读取失败或格式异常时不修改、不伪造备份")
            check(!f.status().lastError.isEmpty, "DNS 读取错误进入状态")
        }
        do {
            let (r, f) = fixture()
            check(f.setAli().0 && f.loadBackup()?.count == 2, "手动 DNS 与自动配置均先备份")
            let first = f.loadBackup()
            let repeated = f.setAli().0, afterRepeat = f.loadBackup()
            check(repeated && afterRepeat == first, "重复修改保留最初的备份")
            check(f.restore().0 && !fm.fileExists(atPath: backup.path), "全部回读正确后删除备份")
            check(r.dns["Wi-Fi"] == ["192.0.2.53"] && r.dns["Ethernet"] == [], "恢复手动 DNS 和 DHCP 原值")
        }
        do {
            let (r, f) = fixture(); _ = f.setAli()
            r.disabled = ["Wi-Fi"]; r.writes = []
            check(!f.restore().0 && f.loadBackup()?.map(\.service) == ["Wi-Fi"], "停用服务保留备份，其余成功项移出待恢复清单")
            check(!r.writes.contains { $0[1] == "Wi-Fi" }, "停用服务不发出写命令")
            r.disabled = []
            check(f.restore().0 && f.loadBackup() == nil && r.dns["Wi-Fi"] == ["192.0.2.53"], "服务恢复后可重试完成")
        }
        do {
            let (r, f) = fixture(); _ = f.setAli()
            let before = try Data(contentsOf: backup)
            r.listCode = 124; r.writes = []
            let restored = f.restore().0, afterFailure = try Data(contentsOf: backup)
            check(!restored && r.writes.isEmpty && afterFailure == before, "服务列表读取失败不删除或改写备份")
            r.listCode = 0; r.failedWrites = ["Wi-Fi"]
            check(!f.restore().0 && f.loadBackup()?.map(\.service) == ["Wi-Fi"], "部分写入失败保留待恢复项")
            r.failedWrites = []; r.ignoreWrites = true
            check(!f.restore().0 && f.loadBackup()?.map(\.service) == ["Wi-Fi"], "命令成功但回读不符时仍保留备份")
            r.ignoreWrites = false
            check(f.restore().0, "部分失败后能再次恢复")
        }
        do {
            try Data("damaged backup".utf8).write(to: backup)
            let (r, f) = fixture(), before = try Data(contentsOf: backup)
            let changed = f.setAli().0, afterFailure = try Data(contentsOf: backup)
            check(!changed && r.writes.isEmpty && afterFailure == before, "损坏备份不被覆盖")
            try fm.removeItem(at: backup)
        }
        do {
            let r = Runner()
            let f = DNSFixer(runner: r, backupURL: nil)
            check(!f.setAli().0 && r.writes.isEmpty, "没有可保存备份的位置时拒绝修改")
        }
    }
}

#if SAFETY_CORE_TESTS
@main enum SafetyCoreTestMain {
    static func main() {
        var passed = 0, failed = 0
        do {
            try SafetyCoreTests.run { ok, name in
                if ok { passed += 1 } else { failed += 1; print("✗ " + name) }
            }
        } catch { failed += 1; print("✗ " + error.localizedDescription) }
        print("safety-core: \(passed) 通过, \(failed) 失败")
        if failed > 0 { exit(1) }
    }
}
#endif
