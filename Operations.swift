import AppKit
import Foundation

/// 等待可观察的结果；发出请求不等于完成，超时也不强制结束应用。
enum OperationCheck {
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    static func wait(timeout: TimeInterval = 8, until condition: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { completion(true) }
            else if Date() >= deadline { completion(false) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() } }
        }
        poll()
    }
    static func message(title: String, verified: Bool) -> String {
        verified ? "已确认完成：" + title : "尚未确认完成：" + title + "，请检查保存对话框或刷新后重试"
    }
}

final class OperationFeedback: ObservableObject {
    static let shared = OperationFeedback()
    @Published var busy = false
    @Published var note = ""
}

extension FixRunner {
    @discardableResult static func perform(_ fix: Fix, completion: @escaping (Bool, String) -> Void = { _, _ in }) -> Bool {
        let feedback = OperationFeedback.shared
        guard !feedback.busy else { return false }
        let targets: [Int32]
        switch fix {
        case .quitApp(let pid, _, _), .closeTab(let pid, _, _, _): targets = [pid]
        case .restartSpotlight: targets = Sys.procs().filter { ["corespotlightd", "helpd", "mds_stores"].contains($0.name) }.map(\.pid)
        case .quitClaude: targets = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }.map(\.processIdentifier)
        case .displayTips: return run(fix)
        case .none: return false
        }
        guard !targets.isEmpty else {
            let message = "目标进程当前未运行，无需处理"
            feedback.note = message; DispatchQueue.main.async { completion(false, message) }; return true
        }
        guard run(fix) else { return false }
        let title = (fix.title ?? "操作").replacingOccurrences(of: "…", with: "")
        feedback.busy = true; feedback.note = "正在核对：" + title
        OperationCheck.wait(until: { targets.allSatisfy { !OperationCheck.processExists($0) } }) { verified in
            feedback.busy = false; feedback.note = OperationCheck.message(title: title, verified: verified)
            if verified {
                switch fix {
                case .restartSpotlight, .quitClaude: CleanStats.shared.addOptimized(1)
                default: break
                }
            }
            Monitor.shared.sampleNow(); completion(verified, feedback.note)
        }
        return true
    }
}
