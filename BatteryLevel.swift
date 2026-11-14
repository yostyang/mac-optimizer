// 2.16 N2 / N3：电量状态的唯一判断
//
// 内置电池、蓝牙外设、单独菜单栏电池图标与合并图标都走 `BatteryLevel.of`：
// - 图形（环、条、菜单栏填充）用状态图形色 good / warn / bad（SwiftUI 与 AppKit 同一组令牌，见 main.swift goodNS 等）
// - 文字用 DS.text 里对应的文字色
// - 低电量不只靠颜色：旁边有警示图标与「电量低 / 电量极低」字样，朗读包含设备名、有效数值和状态
// 视觉分界（D2）：≤ 10% 危险、11–20% 注意。通知的自定义阈值是另一回事，关掉通知不影响这里的视觉状态。
import SwiftUI
import AppKit

enum BatteryLevel: Equatable {
    case critical, low, normal
    static let criticalMax = 10, lowMax = 20
    static func of(_ p: Int) -> BatteryLevel { p <= criticalMax ? .critical : (p <= lowMax ? .low : .normal) }
    /// 图形色（环、条、图标填充）
    var graphic: Color { switch self { case .critical: return bad; case .low: return warn; case .normal: return good } }
    var graphicNS: NSColor { switch self { case .critical: return badNS; case .low: return warnNS; case .normal: return goodNS } }
    /// 数值文字色：正常时用主文字色，不把正常电量染成绿色
    var text: Color { switch self { case .critical: return DS.text.bad; case .low: return DS.text.warn; case .normal: return .primary } }
    /// 非颜色提示：文字与图标（形状不同，灰度下也能区分危险和注意）
    var label: String? { switch self { case .critical: return "电量极低"; case .low: return "电量低"; case .normal: return nil } }
    var symbol: String? { switch self { case .critical: return "exclamationmark.triangle.fill"; case .low: return "exclamationmark.circle.fill"; case .normal: return nil } }
    var key: String { switch self { case .critical: return "critical"; case .low: return "low"; case .normal: return "normal" } }
}

/// 读数时效（N5）：有效 / 缓存（本次没读到，旧值仍在有效窗口内）/ 过期 / 未取得或断连
enum ReadingFreshness: String, Codable, Equatable {
    case fresh, cached, expired, unknown
    var word: String { switch self { case .fresh: return ""; case .cached: return "缓存"; case .expired: return "已过期"; case .unknown: return "未取得" } }
}

enum BatterySpeech {
    /// 朗读：设备名 + 有效数值 + 状态；未知 / 过期不读成 0%，也不按旧值报低电量
    static func label(name: String, percent: Int?, freshness: ReadingFreshness, reason: String = "") -> String {
        switch freshness {
        case .unknown: return name + "，电量未取得" + (reason.isEmpty ? "" : "，" + reason)
        case .expired: return name + "，电量读数已过期"
        case .fresh, .cached:
            guard let p = percent else { return name + "，电量未取得" }
            let lv = BatteryLevel.of(p)
            return name + "，电量 \(p)%" + (lv.label.map { "，" + $0 } ?? "") + (freshness == .cached ? "，缓存读数" : "")
        }
    }
}

/// 警示标记：图标（紧凑处）或图标 + 文字。只在有效或缓存读数且低电量时出现
struct LowBatteryMark: View {
    let level: BatteryLevel
    var showText = true
    var body: some View {
        if let symbol = level.symbol, let label = level.label {
            HStack(spacing: 2) {
                Image(systemName: symbol).font(DS.cap(.semibold)).foregroundColor(level.text)
                    .contrastTarget("battery.badge.\(level.key)", .graphic)
                if showText { Text(label).font(DS.cap(.semibold)).foregroundColor(level.text).lineLimit(1).fixedSize() }
            }
            .help(label)
            .accessibilityHidden(true)   // 朗读由所在行的 accessibilityLabel 统一给出
        }
    }
}

/// 一台设备的电量：数值 + 低电量标记 + 时效。未知显示「—」，不画成 0%；过期不显示旧值
struct BatteryLevelView: View {
    let name: String
    let percent: Int?
    var freshness: ReadingFreshness = .fresh
    var compact = false
    var body: some View {
        let shown = (freshness == .fresh || freshness == .cached) ? percent : nil
        HStack(spacing: 4) {
            if let p = shown {
                let lv = BatteryLevel.of(p)
                Capsule().fill(lv.graphic).frame(width: 6, height: 12).padding(3).contrastTarget("battery.level.\(lv.key)", .graphic)
                Text("\(p)%").font(DS.num(12, .semibold)).foregroundColor(lv.text)
                if freshness == .cached { Text("缓存").font(DS.cap()).foregroundColor(DS.text.secondary) }
                LowBatteryMark(level: lv, showText: !compact)
            } else {
                Text("—").font(DS.num(12, .semibold)).foregroundColor(DS.text.secondary)
                Text(freshness == .expired ? "已过期" : "未取得").font(DS.cap()).foregroundColor(DS.text.secondary)
                    .contrastTarget(freshness == .expired ? "battery.value.stale" : "battery.value.unknown")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BatterySpeech.label(name: name, percent: percent, freshness: freshness))
    }
}
