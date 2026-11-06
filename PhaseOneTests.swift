import AppKit
import SwiftUI

enum PhaseOne {
    static func tests() {
        typealias T = MOTests
        T.sec("第一期：页面路由与键盘契约")
        T.check(Set(navPages.map(\.id)).count == navPages.count, "每个页面有唯一语义标识")
        T.check(navPages.allSatisfy { Page(storageKey: $0.id.storageKey) == $0.id }, "所有页面名能稳定往返")
        T.check(features.count == ToolKind.allCases.count && Set(features.map(\.id)) == Set(ToolKind.allCases),
                "工具种类与导航完整对应，不依赖数组下标路由")
        T.check(Page.notificationPage("battery") == .battery && Page.notificationPage(-2) == .monitor,
                "通知使用页面字符串，同时兼容升级前旧通知")
        T.check(Page.notificationPage("unknown") == nil && Page.notificationPage(-999) == nil,
                "未知通知页面被拒绝")
        T.check(Key.enter != Key.keypadEnter && Key.up != Key.down && Key.escape != Key.space, "主回车和数字键盘回车均有具名键码")
        let original = Nav.shared.sel
        CmdIndex.open(.tool(.vpn))
        T.check(Nav.shared.sel == .tool(.vpn), "语义页面能直接打开 VPN 工具")
        Nav.shared.sel = original

        T.sec("第一期：指标色与状态色")
        T.check(ProcessCPU.color(ProcessCPU.warning - 1) == Color.primary, "未达进程阈值用正文色")
        T.check(ProcessCPU.color(ProcessCPU.warning) == warn && ProcessCPU.color(ProcessCPU.danger) == bad,
                "进程 30/80 阈值与诊断常量共用，状态不再用青蓝")
        let metrics = [DS.metric.cpu, DS.metric.gpu, DS.metric.memory, DS.metric.disk,
                       DS.metric.network, DS.metric.battery, DS.metric.fan]
        T.check(metrics.allSatisfy { $0 != good && $0 != warn && $0 != bad }, "七类指标色与状态色独立")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let bg = NSColor(DS.card).usingColorSpace(.sRGB)!
                let contrasts = metrics.map { NSColor($0).usingColorSpace(.sRGB)! }.map { color -> Double in
                    let a = MOTests.lum(color), b = MOTests.lum(bg)
                    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
                }
                T.check(contrasts.allSatisfy { $0 >= 4.5 }, "指标标签对比度 \(appearance.rawValue)",
                        String(format: "最低 %.2f", contrasts.min() ?? 0))
            }
        }
        T.check(Monitor.detailInterval == 2 && Monitor.lightInterval == 5,
                "界面改版复用既有 2/5 秒采样，没有新增刷新计时器")
    }
}
