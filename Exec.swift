import Foundation

/// 运行外部程序：不经过 shell，参数原样传给程序；标准错误丢弃；超过时限就终止。
/// 只给主 App 用。特权助手有自己的 `RealRunner`（DNSCore.swift），助手源码一改，用户就得重新授权，所以这里不动它。
enum Exec {
    struct Result { let code: Int32; let out: String; let timedOut: Bool }
    static let defaultTimeout: TimeInterval = 10

    /// 线程间传递读到的输出
    private final class Box { let lock = NSLock(); var data = Data() }

    @discardableResult
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = defaultTimeout) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        // 标准错误以前接了一个没人读的 Pipe，写满缓冲区（约 64KB）子进程就会卡住
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Result(code: -1, out: "", timedOut: false) }

        // 一边运行一边读标准输出，输出再多也不会把子进程堵住
        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.data = d; box.lock.unlock()
            readDone.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // 子进程退出后管道会关闭；万一它的子进程还占着管道，最多再等 1 秒
        _ = readDone.wait(timeout: .now() + 1)
        box.lock.lock(); let data = box.data; box.lock.unlock()
        // 超时的进程不读 terminationStatus：进程还没结束时读取会直接抛异常
        return Result(code: timedOut ? -2 : p.terminationStatus, out: String(data: data, encoding: .utf8) ?? "", timedOut: timedOut)
    }
}

/// 登录项（开机启动）：名称只作为 AppleScript 字符串字面量出现，并做转义，不再拼进 shell 命令
enum LoginItems {
    static let osascript = "/usr/bin/osascript"

    /// AppleScript 字符串字面量：转义反斜杠和双引号
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// 每行一个名称，名称里带逗号也不会被拆开
    static let listArgs = [
        "-e", "set AppleScript's text item delimiters to linefeed",
        "-e", "tell application \"System Events\" to set ns to name of every login item",
        "-e", "return ns as text",
    ]
    static func deleteArgs(_ name: String) -> [String] {
        ["-e", "tell application \"System Events\" to delete login item " + literal(name)]
    }

    static func names() -> [String] {
        Exec.run(osascript, listArgs).out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// 返回 osascript 是否正常结束（退出码 0 且没有超时）
    @discardableResult static func delete(_ name: String) -> Bool {
        let r = Exec.run(osascript, deleteArgs(name))
        return r.code == 0 && !r.timedOut
    }
}
