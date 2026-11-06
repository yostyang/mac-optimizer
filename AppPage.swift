import Foundation
import Carbon.HIToolbox

enum ToolKind: String, CaseIterable {
    case resources, startup, browsers, spotlight, virtualMachines, vpn, displayPerformance
}

enum Page: Hashable {
    case overview, monitor, battery, display, network, clean, changes, settings, split
    case tool(ToolKind)

    var storageKey: String {
        switch self {
        case .overview: return "overview"
        case .monitor: return "monitor"
        case .battery: return "battery"
        case .display: return "display"
        case .network: return "network"
        case .clean: return "clean"
        case .changes: return "changes"
        case .settings: return "settings"
        case .split: return "split"
        case .tool(let kind): return "tool." + kind.rawValue
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "overview": self = .overview
        case "monitor": self = .monitor
        case "battery": self = .battery
        case "display": self = .display
        case "network": self = .network
        case "clean": self = .clean
        case "changes": self = .changes
        case "settings": self = .settings
        case "split": self = .split
        default:
            guard storageKey.hasPrefix("tool."), let kind = ToolKind(rawValue: String(storageKey.dropFirst(5))) else { return nil }
            self = .tool(kind)
        }
    }

    /// 只用于读取升级前已经发出的通知；新通知写稳定字符串，不再持久化页面顺序。
    static func notificationPage(_ value: Any?) -> Page? {
        if let key = value as? String { return Page(storageKey: key) }
        switch value as? Int {
        case -2: return .monitor
        case -3: return .battery
        case -6: return .clean
        default: return nil
        }
    }
}

enum Key {
    static let down = UInt16(kVK_DownArrow)
    static let up = UInt16(kVK_UpArrow)
    static let enter = UInt16(kVK_Return)
    static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
    static let escape = UInt16(kVK_Escape)
    static let space = UInt16(kVK_Space)
    static let tab = UInt16(kVK_Tab)
}
