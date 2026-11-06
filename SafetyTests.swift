import Foundation

/// 第零期：外部命令执行与登录项删除的安全性
enum SafetyTests {
    static func tests() {
        typealias T = MOTests
        T.sec("外部命令执行（第零期）")
        try? FileManager.default.removeItem(atPath: "/tmp/mo-selftest-injected")

        let echo = Exec.run("/bin/echo", ["a; touch /tmp/mo-selftest-injected", "$(id)"])
        T.check(echo.code == 0 && echo.out == "a; touch /tmp/mo-selftest-injected $(id)\n", "参数原样传给程序，不经过 shell", echo.out)
        T.check(!FileManager.default.fileExists(atPath: "/tmp/mo-selftest-injected"), "参数里的命令没有被执行")

        var t0 = Date()
        let noisy = Exec.run("/bin/sh", ["-c", "head -c 300000 /dev/zero >&2; echo ok"], timeout: 5)
        T.check(noisy.out == "ok\n" && !noisy.timedOut && Date().timeIntervalSince(t0) < 4, "标准错误输出 300KB 不会卡住",
                String(format: "%.2fs", Date().timeIntervalSince(t0)))

        let big = Exec.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' 'x'"], timeout: 5)
        T.check(big.out.utf8.count == 2_000_000 && !big.timedOut, "标准输出 2MB 能完整读出", "\(big.out.utf8.count) 字节")

        t0 = Date()
        let slow = Exec.run("/bin/sleep", ["5"], timeout: 0.5)
        let took = Date().timeIntervalSince(t0)
        T.check(slow.timedOut && slow.code == -2 && took < 3, "超时后终止子进程", String(format: "%.2fs", took))

        T.check(Exec.run("/nonexistent/tool").code == -1, "程序不存在时返回 -1，不崩溃")
        T.check(sh("echo hi | tr a-z A-Z") == "HI\n", "sh() 仍支持管道")
        T.check(Exec.run("/bin/ps", ["-Axo", "pid=,pcpu=,rss=,comm="]).out.contains("\(getpid()) "), "进程列表能读到本进程")

        T.sec("登录项名称转义（第零期）")
        // 用真实的 AppleScript 解析器做往返：只 return 字面量，不碰 System Events，不会删除任何登录项
        let names = ["微信", "Name \"quoted\"", "back\\slash", "a\" & (do shell script \"touch /tmp/mo-selftest-injected\") & \"", "it's'; touch /tmp/mo-selftest-injected; '"]
        for n in names {
            let r = Exec.run(LoginItems.osascript, ["-e", "return " + LoginItems.literal(n)], timeout: 5)
            T.check(r.code == 0 && r.out == n + "\n", "名称原样往返：" + n, r.out.trimmingCharacters(in: .newlines))
        }
        T.check(!FileManager.default.fileExists(atPath: "/tmp/mo-selftest-injected"), "构造过的登录项名称没有执行命令")
        let del = LoginItems.deleteArgs("x\"y")
        T.check(del.count == 2 && del[0] == "-e" && del[1].hasSuffix("delete login item \"x\\\"y\""), "删除脚本只把名称放进转义后的字面量")
        T.check(!LoginItems.listArgs.joined().contains("\\("), "列表脚本不含插值")

        T.sec("工具页操作核验（第零期）")
        for id in [0, 2, 5] {
            let rows = Loaders.rows(id)
            T.check(rows.filter { $0.action != nil }.allSatisfy { $0.verify != nil }, "工具页 \(id)：退出类操作都带核验", "\(rows.count) 行")
        }
    }
}
