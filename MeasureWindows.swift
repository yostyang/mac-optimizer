// measure.sh 的只读探针：确认被测进程的大面板在采样期始终可见。
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let panel = windows.contains { item in
    guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
    return width >= 300 && height >= 300
}
print(panel ? "panel-visible" : "panel-hidden")
