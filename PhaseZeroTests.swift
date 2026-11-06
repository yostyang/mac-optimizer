import AppKit
import Foundation

private final class LoginItemFixture: CommandRunner {
    var items: [String] = []
    var calls: [(String, [String])] = []
    var failRead = false
    var failRemove = false

    func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        calls.append((path, args))
        if args == ["-l", "JavaScript", "-e", LoginItems.listScript] {
            if failRead { return (1, "") }
            return (0, String(decoding: try! JSONEncoder().encode(items), as: UTF8.self))
        }
        if args.dropLast() == LoginItems.deleteScript[...] {
            if failRemove { return (1, "") }
            items.removeAll { $0 == args.last }
            return (0, "")
        }
        return (-1, "unexpected fixture command")
    }
}

enum PhaseZero {
    static func tests() {
        typealias T = MOTests
        T.sec("第零期：命令参数与登录项安全")
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mo-no-injection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let name = "引号'\"; touch \(marker.path); $(touch \(marker.path)); `touch \(marker.path)`\n逗号, 项目"
        let fixture = LoginItemFixture()
        fixture.items = [name, "另一个, 登录项"]
        let row = LoginItems.row(name, using: fixture)
        if case .success(let names) = LoginItems.names(using: fixture) {
            T.check(names == fixture.items, "JSON 保留登录项中的引号、逗号和换行")
        } else { T.check(false, "JSON 保留登录项中的引号、逗号和换行") }
        T.check(row.verify?() == false, "目标仍在时不能确认禁止自启")
        row.action?()
        let deletion = fixture.calls.first { $0.1.last == name }
        T.check(deletion?.0 == "/usr/bin/osascript" && deletion?.1 == LoginItems.deleteScript + [name],
                "删除登录项使用固定脚本，整个名称仅作为一个 argv 参数")
        T.check(row.verify?() == true && fixture.items == ["另一个, 登录项"], "回读确认指定项消失，保留其他项")
        fixture.failRead = true
        T.check(row.verify?() == false, "读取失败不能伪装成登录项已移除")
        fixture.failRead = false
        fixture.failRemove = true
        fixture.items = [name]
        row.action?()
        T.check(row.verify?() == false, "删除失败且仍存在时不报成功")

        let literal = ProcessRunner.run("/usr/bin/printf", ["%s", name])
        T.check(literal.succeeded && literal.out == name && !FileManager.default.fileExists(atPath: marker.path),
                "真实执行不展开引号、分号、命令替换或反引号")
        let echoed = ProcessRunner.run("/usr/bin/osascript", ["-e", "on run argv", "-e", "return item 1 of argv",
                                                               "-e", "end run", "--", name])
        T.check(echoed.succeeded && echoed.out == name + "\n" && !FileManager.default.fileExists(atPath: marker.path),
                "AppleScript argv 原样接收名称，不执行额外命令", echoed.err)

        T.sec("第零期：命令输出排空与期限")
        let noisy = ProcessRunner.run("/usr/bin/perl", ["-e", "print STDERR 'E' x (2*1024*1024); print STDOUT qq(done\\n);"])
        T.check(noisy.succeeded && noisy.out == "done\n" && noisy.err.utf8.count == ProcessRunner.outputLimit
                && noisy.outputTruncated, "2 MiB 标准错误不会堵住，保留有上限且仍读取 stdout")
        let both = ProcessRunner.run("/usr/bin/perl", ["-e", "for(1..1024){print STDOUT 'O' x 1024; print STDERR 'E' x 1024;}"])
        T.check(both.succeeded && both.out.utf8.count == 1_048_576 && both.err.utf8.count == 1_048_576,
                "stdout/stderr 同时大量输出也完整排空")
        let nonzero = ProcessRunner.run("/usr/bin/perl", ["-e", "print STDOUT 'partial'; print STDERR 'denied'; exit 7;"])
        T.check(nonzero.code == 7 && nonzero.out == "partial" && nonzero.err == "denied" && !nonzero.succeeded,
                "保留非零状态和两路输出，不当作成功")
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = ProcessRunner.run("/usr/bin/perl", ["-e", "$SIG{TERM}='IGNORE'; $|=1; print qq($$\\n); sleep 20;"], timeout: 0.3)
        let pid = Int32(timeout.out.trimmingCharacters(in: .whitespacesAndNewlines))
        T.check(timeout.timedOut && timeout.code == ProcessRunner.timeoutCode
                && ProcessInfo.processInfo.systemUptime - started < 2, "忽略 TERM 的命令仍在期限内结束")
        T.check(pid != nil && !OperationCheck.processExists(pid ?? 0), "超时只回收本次测试子进程，不遗留运行进程")
        let real = RealRunner(timeout: 0.1).run("/bin/sleep", ["20"])
        T.check(real.code == ProcessRunner.timeoutCode, "DNS 与其他调用使用的 RealRunner 也受超时保护")
        T.check(!ProcessRunner.run("/no-such-mo-command", []).succeeded, "启动失败返回错误")
        T.check(!ProcessRunner.run("/usr/bin/printf", ["not run"], timeout: 0).succeeded, "无效期限不启动命令")
        T.check(ProcessRunner.run("/bin/cat", []).succeeded, "stdin 关闭，不等待继承的终端输入")
        T.check(Sys.memoryFreePercentage("System-wide memory free percentage: 83%\n") == 83
                && Sys.memoryFreePercentage("unavailable") == nil, "内存输出用 Swift 解析，无需 shell 管道")

        T.sec("第零期：VPN 冲突只提示")
        let apps = ["LetsVPN", "鹊桥VPN", "Other VPN"].map {
            AppUse(name: $0, cpu: 0, memGB: 0, app: NSRunningApplication.current)
        }
        let issues = Sys.vpnConflicts(apps)
        T.check(issues.count == 3 && issues.allSatisfy { !$0.on }, "所有 VPN 冲突项默认不选中，包括第一个和 LetsVPN")
        T.check(Sys.vpnConflicts(Array(apps.prefix(1))).isEmpty, "单个 VPN 不产生冲突建议")

        T.sec("第零期：工具页结果核验与统计")
        let suite = "mo-phase-zero-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stats = CleanStats(defaults: defaults)
        let operation = ToolOperation()
        operation.verificationTimeout = 0.01
        var requested = 0
        var result: Bool?
        let blocked = Row(icon: nil, title: "有未保存内容的应用", subtitle: "测试", actionTitle: "退出",
                          action: { requested += 1 }, verify: { false })
        T.check(operation.perform(blocked, stats: stats) { ok, _ in result = ok }, "可提交一次工具操作")
        T.check(!operation.perform(blocked, stats: stats), "正在执行时禁止重复提交")
        T.check(T.waitUntil(2) { result != nil } && result == false && requested == 1
                && !operation.busy && operation.note.hasPrefix("尚未确认完成") && stats.optimized == 0,
                "退出被阻止或超时不算完成，不增加统计")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        do { try child.run() } catch { T.check(false, "测试子进程启动", error.localizedDescription); return }
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        result = nil
        operation.verificationTimeout = 2
        let exit = Row(icon: nil, title: "本次测试子进程", subtitle: "测试", actionTitle: "退出",
                       action: { child.terminate() }, verify: { !OperationCheck.processExists(child.processIdentifier) })
        operation.perform(exit, stats: stats) { ok, _ in result = ok }
        T.check(T.waitUntil(3) { result == true && stats.optimized == 1 }
                && operation.note.hasPrefix("已确认完成") && !operation.busy,
                "确认实际退出后才增加一次统计")

        result = nil
        let settings = Row(icon: nil, title: "系统设置", subtitle: "测试", actionTitle: "打开", action: {})
        operation.perform(settings, stats: stats) { ok, _ in result = ok }
        T.check(T.waitUntil(1) { result != nil } && result == false && stats.optimized == 1
                && operation.note.hasPrefix("已发起"), "打开设置等无核验动作不伪报成功、不增加统计")

        result = nil
        var checkedOffMain = false
        let readBack = Row(icon: nil, title: "回读测试", subtitle: "测试", actionTitle: "处理", action: {}, verify: {
            checkedOffMain = !Thread.isMainThread
            return true
        })
        operation.perform(readBack, stats: stats) { ok, _ in result = ok }
        T.check(T.waitUntil(1) { result == true && stats.optimized == 2 } && checkedOffMain,
                "可能阻塞的结果回读在后台执行，完成反馈回主线程")
        let inert = Row(icon: nil, title: "只读信息", subtitle: "测试", actionTitle: nil, action: nil)
        T.check(!operation.perform(inert, stats: stats), "只读项不产生操作和统计")
    }
}
